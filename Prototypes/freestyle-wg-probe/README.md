# Freestyle private VM proof

This is the easiest test of the proposed cmux Cloud transport:

1. Sign in once with Freestyle:

   ```sh
   bunx freestyle@latest login
   ```

2. Start this program from this directory:

   ```sh
   ./connect.sh
   ```

3. Use the VM picker. Press `↑` or `↓` to move, type to filter, and press
   `Enter` to connect. Press `Esc` to clear the filter or `q` to quit.

4. Use the shell. Type `exit` when finished.

The program uses the saved Freestyle login. It does not ask for a WireGuard
file, private IP, endpoint, hash, or timeout.

In a normal terminal it opens a full-screen picker. In a pipe or a terminal
without cursor support it uses a simple text picker.

When connected, the program shows:

- `System VPN started by this tool: none`
- `OS TUN interface added: none`
- `OS routes added: none`
- `WireGuard: running inside this process only`
- `Existing VPNs: left running`

These statements describe this program's actions. A different VPN application
that was already running is outside this program's control. This prototype does
not stop Tailscale or any other VPN.

The selected VM must already have a Freestyle private network and private IPv4
address. A stopped VM is started automatically. The program creates a temporary
WireGuard tunnel, a firewall rule for one temporary TCP port, and a short-lived
shell bridge on the VM. It removes all three when the shell exits. It does not
install a package or change the VM's disk.

The shell is a transport proof. The Freestyle HTTPS API is used only to list the
VM and create the temporary resources. Shell bytes travel to the VM's private
address through the in-process WireGuard and userspace IP stack.

## What a representative test means

There are two separate questions:

1. Can this userspace WireGuard path reach a private VM? Run this program with
   the saved Freestyle login. It creates no kernel WireGuard interface and no
   OS route. An existing Tailscale connection may stay active for the rest of
   your cmux work.
2. Does the path work on a machine with no VPN at all? Run the same command on a
   clean machine or disposable VM where Tailscale is not installed or running.
   A new macOS login is not enough because Tailscale is system-wide. Do not
   disconnect Tailscale on the machine that provides your subrouter.

The second test is the strict fresh-machine check. The first test is the normal
cmux check: it proves that this tool adds no system VPN state while it uses the
already authenticated Freestyle account.

## Login expiration

The client refreshes the Freestyle access token when the API returns `401`,
including during cleanup. It also rereads the saved refresh token, so a token
rotated by another Freestyle CLI process can be used.

If the refresh token itself is expired, run:

```sh
bunx freestyle@latest login
```

Then start a new connection. The prototype cannot delete cloud resources after
the account session is fully invalid until it has a valid login again.

## Development checks

Requires Go 1.23 or newer.

```sh
go test ./...
go vet ./...
./connect.sh selftest
```

`selftest` checks two in-process WireGuard devices over loopback. It does not
contact Freestyle.

The older file-based HTTP check remains available for transport diagnostics:

```sh
go run . check --config ./freestyle.conf --target http://10.100.0.10:8080/probe.bin
```
