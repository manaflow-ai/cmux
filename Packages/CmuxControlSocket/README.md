# CmuxControlSocket

The cmux control-socket domain: the transport and policy layer under the Unix-domain socket that external programs (the cmux CLI, agents, tests) use to drive the app.

This package currently owns the listener's path/bind/probe/lock machinery and its recovery policy, lifted out of the app target's `TerminalController`. The listener loop itself (accept source, client threads, command dispatch) still lives in the app and is planned to move here as an actor service in a later refactor wave.

## Layout

- `Transport/` — `SocketTransport` and its capability extensions (path identity/probe, lock files, bind, client-socket configuration, raw I/O).
- `Policy/` — `SocketListenerPolicy`, the pure decision logic.
- `Model/` — the Sendable value types the two exchange.

## Types

- `SocketTransport` — stateless syscall layer: socket-path identity (`SocketPathIdentity`) and liveness probing (`SocketPathProbeResult`), advisory lock-file arbitration (`SocketPathLockAcquisition`), listener binding (`SocketBindAttemptResult`), accepted-client configuration, `writeAll`, and the one-shot `probeCommand` client.
- `SocketListenerPolicy` — pure decisions: accept-failure classification (`SocketAcceptErrorClassification`) and recovery (`AcceptFailureRecoveryAction`), socket-path unlink rules, and bind-failure fallback from the stable default path to the user-scoped path.
- `SocketListenerHealth` — a point-in-time health snapshot combining listener state with on-disk path checks.

Stage failures carry stable `stage` strings (`SocketStageFailure`) that feed telemetry breadcrumbs and the fallback policy; do not rename existing stages.

## Testing

Both core types are stateless value structs constructed directly; transport tests bind real sockets under unique `/tmp` paths:

```swift
let transport = SocketTransport()
let path = "/tmp/test-\(UUID().uuidString).sock"
#expect(transport.pathProbeResult(at: path) == .stale)

let policy = SocketListenerPolicy(acceptFailureRearmThreshold: 3)
#expect(policy.shouldRearm(consecutiveFailures: 3))
```

Run with `swift test --package-path Packages/CmuxControlSocket`.
