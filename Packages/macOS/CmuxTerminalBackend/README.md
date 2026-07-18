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

The terminal-authority handshake requires protocol v8 and these capabilities:

- `canonical-topology-snapshot-v1`
- `durable-session-identity-v1`
- `presentation-registry-v1`
- `stable-entity-uuid-v1`
- `topology-resume-v1`

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
