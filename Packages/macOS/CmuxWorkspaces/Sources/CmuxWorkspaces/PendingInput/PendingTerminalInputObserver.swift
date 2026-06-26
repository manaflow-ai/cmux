import Foundation

/// A single queued "send this input once the surface is ready" registration.
///
/// Holds the opaque `NotificationCenter` observer token returned by the host
/// when it observes `.terminalSurfaceDidBecomeReady` for a panel's surface. The
/// ``PendingTerminalInputCoordinator`` keeps these in a per-panel list and clears
/// the token (via `removeObserver`) when the queued input fires, times out, or
/// the panel's surfaces are pruned.
///
/// `@unchecked Sendable`: the only mutable state is the observer token, mutated
/// solely on the `@MainActor` coordinator, but instances are captured in the
/// `@Sendable` notification and timeout closures so the type must be `Sendable`.
/// This mirrors the legacy `WorkspacePendingTerminalInputObserver` lifted from
/// `Workspace.swift`.
final class PendingTerminalInputObserver: @unchecked Sendable {
    var observer: (any NSObjectProtocol)?
}
