# Embedded tailnet controls

The daemon-owned embedded node is opt-in. Until a person calls
`_acpmux/tailnet/start`, no node is constructed, no state directory is made,
and no tailnet listener is opened. A start resumes the saved login when one
exists; a new node reports `state: "needs_login"` and keeps its browser URL in
memory for the person who requested it.

The controls are accepted only on a local, person-proven connection:

- `_acpmux/tailnet/start` starts the node without waiting for sign-in.
- `_acpmux/tailnet/login` asks a running node for a fresh sign-in URL.
- `_acpmux/tailnet/state` returns `state`, optional `dns_name`, `ips`, and
  `error`. The sign-in URL is included only for the person response.
- `_acpmux/tailnet/logout` signs a live node out and closes ingress connections.
  It never starts a node. When stopped, it only removes the saved local login
  and opt-in marker; it does not create state or revoke the device remotely.
  If logout races an already-started close, local cleanup finishes but logout
  reports that remote sign-out was not confirmed. The error directs the user
  to remove the device in the Tailscale admin console; it never silently
  reports successful remote sign-out or restarts the node to attempt it.
- `_acpmux/tailnet/join` joins the node to the person's own tailnet with a
  one-time auth key (`tailnet/embedded_join.rs`). Params (v1, camelCase,
  unknown fields ignored): `key` (required), `controlUrl` (a Headscale server;
  absent means Tailscale), `allowHttp`, `hostname`, `tags`, `ephemeral`,
  `switch`. The reply is the state reply plus `join` (the profile, never the
  key); `state` carries the same `join` once a node has joined.

### Joining your own tailnet

The request goes through `cmux-tailnet-join`'s `check()` (key shape, server
URL, DNS-label hostname, `tag:` names) before anything changes. A refusal
names the field and never echoes the params.

- The key signs in once: it stays in memory until the next start hands it to
  `Node::new`, and that config is dropped right after. It is never written to
  disk, a log, argv, settings or a reply. `join.json` in the state directory
  keeps only the server, hostname, tags and ephemeral flag, so a relaunch's
  resume reconnects to the same tailnet with the saved node key.
- If the node is already signed in (`_current-profile` in `tailscaled.state`)
  or running, a join is refused and changes nothing unless `switch` is set; a
  switch logs the old node out (clearing its state) first.
- A plain `http://` server needs `allowHttp` for that join, whatever the
  address: nothing is auto-detected as private.
- Logout (leave) removes `tailscaled.state`, the opt-in marker and `join.json`.
- Tags reach tsnet through `TsnetSetAdvertiseTags` (`patches/0004`).
- The node is userspace tsnet: the host's own tailscaled, its routes, exit
  node and DNS are never touched (no accept-routes or advertise-routes).
- There is no CLI join: the unix socket is shared with agents, and an agent
  that could join this Mac to a tailnet of its choosing could exfiltrate
  through it. Only the proven person (the app) may call it.
- Any UI that offers to remember a key keeps it in the Keychain this-device-only
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable`
  false), one item per tailnet, with a forget button. acpmux itself stores none.

The state stream is event-driven from the node's IPN bus. It has no polling
timer. A failed watch clears the node so a later explicit start can retry; a
generation fence prevents an old watch from changing a replacement node's
state. Each start, login, logout and shutdown runs on its own task, so a caller
that goes away mid-request never leaves the controller half-changed. Daemon
shutdown closes the node but leaves its saved login for the next explicit start,
and no start is accepted after it begins.
An explicit start records an opt-in marker before starting the node. A startup
failure reports an error but keeps that intent, so the next daemon launch retries.
Daemon startup resumes only that marker, and only when it is a regular file
owned by this user inside the private state directory; a symlink, FIFO or
shared directory is refused. An untouched installation creates no state or
node. Every remote sign-out (logout, or a close that a queued logout turns into
one) clears the marker first, so an interrupted or failed sign-out cannot
silently reconnect on the next launch. The listener service drains connections
before replacing a node or DNS name, and a listener failure waits for an
explicit retry. Daemon shutdown fences the service first, after any supervisor
action already under way: from then on nothing starts, replaces or retires a
listener or node (a failure cleanup queued earlier leaves its node to shutdown),
and the ingress closes through the daemon's WebSocket shutdown (1012 on
restart) before the node closes.
Builds with the `tailnet` feature list the five methods in `initialize`'s
`extensions`; other builds answer them with `not_built`.

Tailnet ingress receives the controller's live `Node` and the daemon's same
`Arc<Hub>`. Pairing tickets are minted and redeemed by that Hub's one pairing
store, so the authenticated tailnet identity and acpmux identity cannot drift
into separate stores.
