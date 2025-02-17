defmodule SSHClientKeyAPI do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias SSHClientKeyAPI.KeyError

  @behaviour :ssh_client_key_api
  @key_algorithms :ssh.default_algorithms()[:public_key]

  @doc """
  Returns a tuple suitable for passing the `SSHKit.SSH.connect/2` as the `key_cb` option.

  ## Options

    * `:identity` - [`binary`] providing the ssh key (required)

    * `:known_hosts` - [`IO.device`] providing the known hosts list. If providing a
      File IO, it should have been opened in `:write` mode (required)

    * `:silently_accept_hosts` - [`boolean`] silently accept and add new hosts to the
      known hosts. By default only known hosts will be accepted.

    * `:passphrase` - [`binary`] passphrase if your key is protected (optional)

  By default it will use the the files found in `System.user_home!/0`.

  ## Examples

      key = File.read!("path/to/keyfile")
      known_hosts = File.open!("path/to/known_hosts")
      cb = SSHClientKeyAPI.with_options(identity: key, known_hosts: known_hosts)
      SSHKit.SSH.connect("example.com", key_cb: cb)

  """
  @spec with_options(opts :: list) :: {atom, list}
  def with_options(opts \\ []) do
    opts = with_defaults(opts)

    opts =
      if opts[:known_hosts] do
        Keyword.put(opts, :known_hosts_data, IO.binread(opts[:known_hosts], :all))
      else
        opts
      end

    {__MODULE__, opts}
  end

  def add_host_key(hostname, key, opts) do
    case silently_accept_hosts(opts) do
      true ->
        if known_hosts = known_hosts_data(opts) do
          :ssh_file.decode(known_hosts, :known_hosts)
          |> (fn decoded -> decoded ++ [{key, [{:hostnames, [hostname]}]}] end).()
          |> :ssh_file.encode(:known_hosts)
          |> (fn encoded -> IO.binwrite(known_hosts(opts), encoded) end).()
        else
          :ok
        end

      _ ->
        message = """
        Error: unknown fingerprint found for #{inspect(hostname)} #{inspect(key)}.
        You either need to add a known good fingerprint to your known hosts file for this host,
        *or* pass the silently_accept_hosts option to your client key callback
        """

        {:error, message}
    end
  end

  def is_host_key(key, hostname, alg, opts) when alg in @key_algorithms do
    silently_accept_hosts(opts) ||
      opts
      |> known_hosts_data
      |> to_string
      |> :ssh_file.decode(:known_hosts)
      |> has_fingerprint(key, hostname)
  end

  def is_host_key(_, _, alg, _) do
    IO.puts("unsupported host key algorithm #{inspect(alg)}")
    false
  end

  def user_key(_alg, opts) do
    opts
    |> identity
    |> to_string
    |> :public_key.pem_decode()
    |> List.first()
    |> decode_pem_entry(passphrase(opts))
  end

  defp decode_pem_entry(nil, _phrase) do
    raise KeyError, {:unsupported_algorithm, :unknown}
  end

  defp decode_pem_entry({_type, _data, :not_encrypted} = entry, _) do
    {:ok, :public_key.pem_entry_decode(entry)}
  end

  defp decode_pem_entry({_type, _data, {alg, _}}, nil) do
    raise KeyError, {:passphrase_required, alg}
  end

  defp decode_pem_entry({_type, _data, {alg, _}} = entry, phrase) do
    {:ok, :public_key.pem_entry_decode(entry, phrase)}
  rescue
    _e in MatchError ->
      # credo:disable-for-next-line Credo.Check.Warning.RaiseInsideRescue
      raise KeyError, {:incorrect_passphrase, alg}
  end

  defp identity(opts) do
    cb_opts(opts)[:identity]
  end

  defp silently_accept_hosts(opts) do
    cb_opts(opts)[:silently_accept_hosts]
  end

  defp known_hosts(opts) do
    cb_opts(opts)[:known_hosts]
  end

  defp known_hosts_data(opts) do
    cb_opts(opts)[:known_hosts_data]
  end

  defp passphrase(opts) do
    cb_opts(opts)[:passphrase]
  end

  defp cb_opts(opts) do
    opts[:key_cb_private]
  end

  defp has_fingerprint(fingerprints, key, hostname) do
    Enum.any?(fingerprints, fn {k, v} -> k == key && Enum.member?(v[:hostnames], hostname) end)
  end

  defp with_defaults(opts) do
    opts
    |> Keyword.put_new(:silently_accept_hosts, false)
  end
end
