# CmuxTerminalBackendService

This package owns the launchd-supervised cmux-tui terminal backend. The executable owns PTYs independently of the Swift app, so quitting or restarting cmux does not terminate terminal sessions.

Bootstrap validates the bundled daemon, renderer, and matching build-ID sidecars before copying them into `~/Library/Application Support/cmux/terminal-backend/<bundle-id>/versions/<build-id>/`. The installed manifest binds exact filenames, byte counts, and SHA-256 hashes. Installed directories belong to the current user, executables use mode `0500`, metadata uses `0400`, and symlinks or group/world-writable artifacts fail closed. launchd receives an absolute `Program` path into that version directory. The daemon resolves `cmux-terminal-renderer` as an exact sibling, so a running vN cannot load vN+1's renderer after the app bundle is replaced.

At launch, cmux validates and probes the pair named by the loaded descriptor before inspecting the current app bundle. Once vN is ready, staging the current bundle is best effort, so a missing or corrupt vN+1 cannot block reconnection. An update stages vN+1 without replacing a loaded vN descriptor. `activateIfServiceStopped` defers while vN remains loaded. An explicit safe or idle handoff first stops the service, then installs the vN+1 descriptor. Automatic version garbage collection is disabled because process-local state cannot protect another app instance's staged version. The explicit maintenance API preserves caller-specified builds and versions referenced by live daemon executable paths.

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

Registration, status lookup, pair installation, and bundle inspection run on the coordinator actor rather than the app's main actor. `stateUpdates()` exposes a sendable newest-value stream for UI presentation. Normal launch never unregisters or re-registers an enabled agent. A compatible new frontend connects to the already-running daemon through protocol negotiation, so replacing or restarting the Swift app does not restart shells. An incompatible frontend receives a read-only compatibility result. The explicit `unregister()` API is reserved for deletion and safe-handoff workflows because it terminates backend-owned PTYs when canonical state is still active. Automatic atomic idle handoff and PTY ownership transfer are not implemented, so the production gate remains disabled.

Readiness uses one absolute deadline while launchd creates or restarts the socket. Missing sockets, refused connections, and peers that exit during their handshake receive bounded exponential backoff. Identity, code-signing, protocol, session, and authority failures stop immediately. The probe authenticates `LOCAL_PEERTOKEN` from the exact protocol socket, confirms its PID and effective UID against the socket credentials, asks Security.framework for the live dynamic code by audit token, and resolves the executable with `proc_pidpath_audittoken`. This prevents PID reuse between socket authentication, signature validation, and path lookup.

Tests inject launch-control, build-ID, code-signature, and live-process seams. They do not register a real login item or mutate the developer's launchd state. Code signatures and exact executable paths protect the app from unrelated processes. A malicious process running as the same macOS user can rewrite that user's Application Support and LaunchAgents directories, which remains outside this crash-isolation boundary.
