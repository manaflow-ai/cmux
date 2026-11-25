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
Builds with the `tailnet` feature list the four methods in `initialize`'s
`extensions`; other builds answer them with `not_built`.

Tailnet ingress receives the controller's live `Node` and the daemon's same
`Arc<Hub>`. Pairing tickets are minted and redeemed by that Hub's one pairing
store, so the authenticated tailnet identity and acpmux identity cannot drift
into separate stores.
