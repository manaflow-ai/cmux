# CmuxControlSocket

The cmux control-socket domain: the listener and the transport/policy layer under the Unix-domain socket that external programs (the cmux CLI, agents, tests) use to drive the app.

This package owns the listener server (`SocketControlServer`: reservation, bind/listen lifecycle, accept source with backoff/rearm recovery, socket-path monitor) plus the path/bind/probe/lock machinery and recovery policy under it, lifted out of the app target's `TerminalController`. Client command handling (the per-connection read loop, auth, v1/v2 dispatch) still lives in the app and is planned to move here in the control-plane coordinator wave.

## Layout

- `Server/` — `SocketControlServer`, its host-event seam, the bounded async
  connection pool, async client transport, polling limiter, read snapshots,
  and the telemetry dedupe cache.
- `Transport/` — `SocketTransport` and its capability extensions (path identity/probe, lock files, bind, client-socket configuration, peer verification, raw I/O).
- `Policy/` — `SocketListenerPolicy`, the pure decision logic.
- `Model/` — the Sendable value types they exchange.
- `CmuxControlSocketAtomicsC/` — macOS 14-compatible C11 atomic pointer and
  reader-count primitives used by the snapshot publication seam.

## Types

- `SocketControlServer` — the listener state machine: startup path reservation, `start`/`stop`, generation-counted accept source with failure backoff and rearm, the socket-path monitor, and synchronous reads (`isRunning`, `activeSocketPath`, `listenerHealth`). State lives under one lock because every driver is synchronous (DispatchSource handlers, client reader threads, app-termination teardown); see the type docs for the carve-out rationale.
- `SocketControlServerConfiguration` and `SocketControlServer.reconfigure(accessMode:)` — the value snapshot and live policy update seam used by config reload and Settings changes. Connection workers read the published current mode; active listeners reapply file permissions without rebinding, and `off` stops the listener.
- `SocketControlServerEvents` — the host-callback seam: telemetry breadcrumbs/failures, listener-started, accepted-client hand-off (host owns the fd), path-missing and rearm restart triggers, last-socket-path recording.
- `SocketFastPathState` — per-surface dedupe for high-frequency `report_*` telemetry.
- `SocketTransport` — stateless syscall layer: socket-path identity (`SocketPathIdentity`) and liveness probing (`SocketPathProbeResult`), advisory lock-file arbitration (`SocketPathLockAcquisition`), listener binding (`SocketBindAttemptResult`), accepted-client configuration, peer PID/UID/ancestry checks, `writeAll`, and the one-shot `probeCommand` client.
- `SocketListenerPolicy` — pure decisions: accept-failure classification (`SocketAcceptErrorClassification`) and recovery (`AcceptFailureRecoveryAction`), socket-path unlink rules, and bind-failure fallback from the stable default path to the user-scoped path.
- `SocketListenerHealth` — a point-in-time health snapshot combining listener state with on-disk path checks.
- `ControlClientWorkerPool` — actor-owned FIFO admission with bounded active
  and pending async connection jobs. Jobs suspend on I/O or main-actor hops;
  they do not create one thread per client.
- `ControlReadSnapshotStore` — immutable typed read results published by the
  app's main actor and synchronously readable by socket workers without an
  actor hop. Reads use a macOS-14-compatible C11 atomic pointer; entries are
  keyed by method plus canonical params.
- `ControlClientRateLimiter` — per-connection token-bucket backpressure for
  high-frequency list/tree/top/read-text polling.

Accept-source recovery is bounded by the policy's configured maximum backoff
(5 seconds by default). A fatal descriptor error or a persistent accept-failure
streak emits `socket.listener.rearm.started`, parks the listener for the
reported `delayMs`, and then emits `socket.listener.rearm.ready` when the host
claims the generation. A successful restart preserving the failure streak emits
`socket.listener.rearm.completed`; `socket.listener.rearm.failed` marks a
restart that could not bind. The interval is the recovery-clock delay supplied
to the host, so a host that does not claim the generation must surface that
failure rather than silently treating the listener as healthy.

Stage failures carry stable `stage` strings (`SocketStageFailure`) that feed telemetry breadcrumbs and the fallback policy; do not rename existing stages.

## Testing

The server is constructed with an injected initial path and a recording event seam; tests bind real sockets under unique temp paths:

```swift
let server = SocketControlServer(
    initialSocketPath: path,
    notificationCenter: .default,
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

Run with `swift test --package-path Packages/macOS/CmuxControlSocket`.
