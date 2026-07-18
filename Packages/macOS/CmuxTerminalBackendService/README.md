# CmuxTerminalBackendService

This package owns registration of the app-bundled, launchd-supervised cmux-tui terminal backend. The executable owns PTYs independently of the Swift app, so quitting or restarting cmux does not terminate terminal sessions.

`BackendServiceDescriptor` derives a launchd label, plist filename, cmux-tui session, socket filename, and durable state namespace from the normalized app bundle identifier. Production keeps the stable `cmux` session. Other bundles use the first 128 bits of SHA-256 encoded as lowercase base32, which keeps launchd arguments and Unix socket paths short while isolating development, staging, and nightly state. Swift and shell validate the same checked-in identity vectors.

The app composition root constructs `BackendServiceBootstrapCoordinator` with an explicit activation policy, bundle inspection, and registration adapter:

```swift
let descriptor = BackendServiceDescriptor(bundleIdentifier: bundleIdentifier)!
let coordinator = BackendServiceBootstrapCoordinator(
    activationPolicy: BackendServiceActivationPolicy(buildSettingValue: "YES"),
    inspection: BackendServiceBundleInspection(
        bundleURL: bundleURL,
        descriptor: descriptor
    ),
    registration: registration,
    readinessChecker: readinessChecker
)
let result = try await coordinator.ensureRegistered()
```

Registration, status lookup, and bundle inspection run on the coordinator actor rather than the app's main actor. `stateUpdates()` exposes a sendable newest-value stream for UI presentation. Normal launch never unregisters or re-registers an enabled agent. A compatible new frontend connects to the already-running daemon through protocol negotiation, so replacing or restarting the Swift app does not restart shells. An incompatible frontend receives a read-only compatibility result. The explicit `unregister()` API waits for process termination and is reserved for deletion workflows because it terminates backend-owned PTYs. Live daemon executable handoff and PTY ownership transfer are not implemented, so the production gate remains disabled; explicitly restarting an incompatible daemon terminates its shells.

Readiness uses one absolute deadline while launchd creates or restarts the socket. Missing sockets, refused connections, and peers that exit during their handshake receive bounded exponential backoff. Identity, code-signing, protocol, session, and authority failures stop immediately. The probe authenticates `LOCAL_PEERTOKEN` from the exact protocol socket, confirms its PID and effective UID against the socket credentials, asks Security.framework for the live dynamic code by audit token, and resolves the executable with `proc_pidpath_audittoken`. This prevents PID reuse between socket authentication, signature validation, and path lookup.

Tests inject a fake `BackendServiceRegistration` and a temporary app bundle. They do not register a real login item or mutate the developer's service-management state.
