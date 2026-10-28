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
- `_acpmux/tailnet/logout` signs the node out and closes ingress connections.

The state stream is event-driven from the node's IPN bus. It has no polling
timer. A failed watch clears the node so a later explicit start can retry; a
generation fence prevents an old watch from changing a replacement node's
state. Daemon shutdown closes the node but leaves its saved login for the next
explicit start.

Tailnet ingress receives the controller's live `Node` and the daemon's same
`Arc<Hub>`. Pairing tickets are minted and redeemed by that Hub's one pairing
store, so the authenticated tailnet identity and acpmux identity cannot drift
into separate stores.
