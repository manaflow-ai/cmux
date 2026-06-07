# CmuxControlSocket

The cmux control-socket domain: the listener and the transport/policy layer under the Unix-domain socket that external programs (the cmux CLI, agents, tests) use to drive the app.

This package owns the listener server (`SocketControlServer`: reservation, bind/listen lifecycle, accept source with backoff/rearm recovery, socket-path monitor) plus the path/bind/probe/lock machinery and recovery policy under it, lifted out of the app target's `TerminalController`. Client command handling (the per-connection read loop, auth, v1/v2 dispatch) still lives in the app and is planned to move here in the control-plane coordinator wave.

## Layout

- `Server/` — `SocketControlServer`, its host-event seam, and the telemetry dedupe cache.
- `Transport/` — `SocketTransport` and its capability extensions (path identity/probe, lock files, bind, client-socket configuration, peer verification, raw I/O).
- `Policy/` — `SocketListenerPolicy`, the pure decision logic.
- `Model/` — the Sendable value types they exchange.

## Types

- `SocketControlServer` — the listener state machine: startup path reservation, `start`/`stop`, generation-counted accept source with failure backoff and rearm, the socket-path monitor, and synchronous reads (`isRunning`, `activeSocketPath`, `listenerHealth`). State lives under one lock because every driver is synchronous (DispatchSource handlers, client reader threads, app-termination teardown); see the type docs for the carve-out rationale.
- `SocketControlServerEvents` — the host-callback seam: telemetry breadcrumbs/failures, listener-started, accepted-client hand-off (host owns the fd), path-missing and rearm restart triggers, last-socket-path recording.
- `SocketFastPathState` — per-surface dedupe for high-frequency `report_*` telemetry.
- `SocketTransport` — stateless syscall layer: socket-path identity (`SocketPathIdentity`) and liveness probing (`SocketPathProbeResult`), advisory lock-file arbitration (`SocketPathLockAcquisition`), listener binding (`SocketBindAttemptResult`), accepted-client configuration, peer PID/UID/ancestry checks, `writeAll`, and the one-shot `probeCommand` client.
- `SocketListenerPolicy` — pure decisions: accept-failure classification (`SocketAcceptErrorClassification`) and recovery (`AcceptFailureRecoveryAction`), socket-path unlink rules, and bind-failure fallback from the stable default path to the user-scoped path.
- `SocketListenerHealth` — a point-in-time health snapshot combining listener state with on-disk path checks.

Stage failures carry stable `stage` strings (`SocketStageFailure`) that feed telemetry breadcrumbs and the fallback policy; do not rename existing stages.

## Testing

The server is constructed with an injected initial path and a recording event seam; tests bind real sockets under unique temp paths:

```swift
let server = SocketControlServer(
    initialSocketPath: path,
    events: recorder.makeEvents()  // closures appending into a lock-guarded recorder
)
#expect(server.start(socketPath: path, accessMode: .cmuxOnly))
let fd = connectToUnixSocket(path)  // accept fires events.clientAccepted(fd, peerPid)
server.stop()                       // unlinks the path, releases the lock

let transport = SocketTransport()
#expect(transport.pathProbeResult(at: path) == .stale)

let policy = SocketListenerPolicy(acceptFailureRearmThreshold: 3)
#expect(policy.shouldRearm(consecutiveFailures: 3))
```

Run with `swift test --package-path Packages/CmuxControlSocket`.
