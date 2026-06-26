public import Foundation

/// The workspace-side seam ``PendingTerminalInputCoordinator`` drives the
/// app-target `TerminalPanel`/surface state through when queuing terminal input
/// until a surface's shell is ready.
///
/// **Why a synchronous read-plus-side-effect protocol and not value snapshots.**
/// The legacy `Workspace.sendInputWhenReady(_:to:)` ran as a single MainActor
/// turn: it checked surface readiness, sent input or registered a one-shot
/// `.terminalSurfaceDidBecomeReady` observer on the panel's surface, then asked
/// the surface to start in the background. Every step touches live app-target
/// state (`TerminalPanel.surface`, `TerminalPanel.sendInput`, the workspace panel
/// registry, and `NotificationCenter`) that cannot cross into the package.
/// Routing each through a synchronous panel-id seam preserves the exact in-turn
/// ordering; the coordinator owns only the pending-registration registry and its
/// bookkeeping.
///
/// The app-target panel types never cross the boundary: panels are addressed by
/// `UUID`, and the surface-ready observer is registered app-side (it needs the
/// panel's surface object as the notification `object`), with the coordinator's
/// fire/timeout decision handed back through the `onReady` closure.
@MainActor
public protocol PendingTerminalInputHosting: AnyObject {
    /// Whether the terminal panel's surface is already live (legacy
    /// `panel.surface.surface != nil`). When `true`, input is sent immediately.
    func pendingInputIsSurfaceReady(forPanelId panelId: UUID) -> Bool

    /// Sends `text` to the terminal panel resolved from `panelId`, dropping it if
    /// the panel is no longer a terminal panel (legacy
    /// `if let panel = panels[panelId] as? TerminalPanel { panel.sendInput(text) }`).
    func pendingInputSendInput(_ text: String, toPanelId panelId: UUID)

    /// Registers a one-shot `.terminalSurfaceDidBecomeReady` observer on the
    /// panel's surface and returns the opaque token (legacy
    /// `NotificationCenter.default.addObserver(forName: .terminalSurfaceDidBecomeReady,`
    /// `object: panel.surface, queue: .main)`). `onReady` runs on the main queue
    /// when the surface becomes ready; it is the coordinator's
    /// has/remove/send decision. Returns `nil` when no terminal panel resolves.
    func pendingInputObserveSurfaceReady(
        forPanelId panelId: UUID,
        onReady: @escaping @Sendable () -> Void
    ) -> (any NSObjectProtocol)?

    /// Asks the panel's surface to start in the background if it has not yet
    /// (legacy `panel.surface.requestBackgroundSurfaceStartIfNeeded()`).
    func pendingInputRequestBackgroundSurfaceStart(forPanelId panelId: UUID)
}
