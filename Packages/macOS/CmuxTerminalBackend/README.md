# CmuxTerminalBackend

This package is the Swift control-plane client for the persistent `cmux-tui`
backend. It does not own PTYs, terminal parsing, rendering, windows, or app
state.

The macOS Unix transport returns `LOCAL_PEERPID`, `LOCAL_PEERCRED`, and
`LOCAL_PEERTOKEN` from the same connected socket. Callers authenticate the
opaque audit token with operating-system APIs instead of relying on a reusable
PID alone.

`BackendProtocolClient` correlates requests with responses while delivering a
bounded event stream. Buffer overflow closes the connection so callers must
take a new atomic snapshot instead of projecting state across a hidden gap.

Every connection sends `identify` before any state command. The handshake
returns an explicit `readWrite` or `readOnly` result with both protocol ranges,
the mutually selected protocol when one exists, and missing capabilities.

Mutation authority requires protocol v9 and these capabilities:

- `canonical-topology-snapshot-v1`
- `durable-session-identity-v1`
- `ensure-terminal-v1`
- `presentation-registry-v1`
- `projection-state-reconnect-v1`
- `renderer-semantic-scene-v1`
- `renderer-worker-supervision-v1`
- `reparent-terminal-v1`
- `stable-entity-uuid-v1`
- `terminal-accessibility-v1`
- `terminal-control-lease-v1`
- `terminal-split-leases-v1`
- `terminal-lease-transfer-v1`
- `terminal-input-delegation-v1`
- `terminal-input-groups-v1`
- `terminal-global-input-order-v1`
- `terminal-input-idempotency-v1`
- `terminal-input-receipt-ack-v1`
- `terminal-interaction-v1`
- `terminal-link-hit-v1`
- `terminal-ordered-input-v1`
- `terminal-activity-v1`
- `topology-resume-v1`

A protocol-v8 backend, a non-overlapping range, or a backend missing any
required mutation capability stays connected read-only. Identity and
compatibility diagnostics remain available. Canonical topology is also read
when the ranges overlap and the backend advertises both snapshot and resume
capabilities; otherwise the connection remains diagnostic-only. The protocol
client rejects every mutation locally before allocating a request ID or
writing to the transport. The diagnostic includes the localized `updateCmux`
action for host UI.

`terminal-accessibility-snapshot` requires both the owned presentation
generation and `expected_content_sequence`. The response repeats
`content_sequence`; clients reject a mismatch. This binds VoiceOver text,
cursor, selection, links, and hit testing to pixels that Metal reported as
presented, rather than a newer received or canonical frame.

The client calls `topology-snapshot`, installs the validated nested topology,
then calls `subscribe-topology` with the exact daemon instance, durable session,
and revision.
Each accepted delta must name the same daemon and session, use the installed
revision as its base, and advance by exactly one. A daemon replacement,
retention gap, slow consumer, malformed tree, or sequence exhaustion forces a
resnapshot.

Canonical topology contains structure only. Connection-owned presentations
carry window selection, zoom, and scroll through UUID-only ancestry-validated
commands. Legacy numeric IDs remain command-compatible; Swift keys durable
state by typed UUIDs and validates layout references, identity uniqueness, and
split ratios before publishing a topology.

A writable session uses `ensure-terminals` for bounded cold-terminal restores
when the backend advertises `ensure-terminals-v1`. It issues ordered singular
`ensure-terminal` commands when that optional capability is absent.
