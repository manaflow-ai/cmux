public import Foundation

/// A live one-shot surface-readiness observation registered through
/// ``PendingTerminalInputHosting``.
///
/// The legacy `WorkspacePendingTerminalInputObserver` box wrapped the
/// `NSObjectProtocol` token returned by
/// `NotificationCenter.default.addObserver(forName:.terminalSurfaceDidBecomeReady …)`
/// keyed on the panel's live `TerminalSurface`. That token, the surface it is
/// scoped to, and the `NotificationCenter` removal are app-target live state, so
/// the box stays behind this seam: ``PendingTerminalInputCoordinator`` holds it
/// only as an opaque identity in its per-panel registry, compares handles with
/// `===`, and asks the host to ``cancel()`` (remove the underlying observer)
/// when a registration is consumed, times out, or its panel is torn down.
@MainActor
public protocol PendingTerminalInputObservation: AnyObject {
    /// Removes the underlying `NotificationCenter` observer, mirroring the legacy
    /// `removeObserver(observer)` + `observer = nil` clear. Idempotent: calling
    /// it twice is a no-op, matching the legacy guard on the optional token.
    func cancel()
}

/// The app-target live-state seam ``PendingTerminalInputCoordinator`` drives when
/// it queues terminal input until a panel's shell surface becomes ready.
///
/// The coordinator owns the value-typed machinery (the per-panel registry of
/// pending observations and the one-shot wait/timeout policy). The reads and
/// writes it drives, however, are app-target live state that cannot move until
/// the workspace god model and its `TerminalPanel` are themselves packaged (the
/// Wave-4 decomposition): the panel registry lookup
/// (`Workspace.panels[panelId] as? TerminalPanel`), the surface-readiness probe
/// (`panel.surface.surface != nil`), the input write (`panel.sendInput(_:)`),
/// the background-surface start kick
/// (`panel.surface.requestBackgroundSurfaceStartIfNeeded()`), and the
/// `NotificationCenter` `.terminalSurfaceDidBecomeReady` observer keyed on the
/// live `panel.surface`. The host owns all of that; the coordinator owns only
/// the registry bookkeeping and the decision of when to send, wait, or drop.
///
/// A conformer reproduces the legacy private `Workspace` bodies exactly:
/// `panel.surface.surface != nil`, `panel.sendInput(text)`,
/// `panel.surface.requestBackgroundSurfaceStartIfNeeded()`, and the one-shot
/// `addObserver(forName:.terminalSurfaceDidBecomeReady, object: panel.surface,
/// queue: .main)` install plus its `removeObserver` teardown.
@MainActor
public protocol PendingTerminalInputHosting: AnyObject {
    /// Whether the panel already exposes a live shell surface, mirroring the
    /// legacy fast-path `panel.surface.surface != nil`. When `true` the
    /// coordinator sends immediately without registering a wait.
    func isTerminalSurfaceReady(forPanelId panelId: UUID) -> Bool

    /// Sends `text` to the panel's terminal, mirroring the legacy
    /// `panel.sendInput(text)`. Called once on the ready fast path and once from
    /// the ready-notification callback (after re-resolving the panel through the
    /// registry, exactly as the legacy `self.panels[panelId] as? TerminalPanel`
    /// re-lookup did); a no-op when the panel no longer exists.
    func sendTerminalInput(_ text: String, toPanelId panelId: UUID)

    /// Kicks a background surface start for the panel if one is not already
    /// running, mirroring the legacy
    /// `panel.surface.requestBackgroundSurfaceStartIfNeeded()` called right after
    /// the observer is registered.
    func requestBackgroundSurfaceStart(forPanelId panelId: UUID)

    /// Registers a one-shot `.terminalSurfaceDidBecomeReady` observer scoped to
    /// the panel's live surface, mirroring the legacy
    /// `addObserver(forName:object:panel.surface,queue:.main)`. The returned
    /// handle is the coordinator's opaque registry entry (the legacy
    /// `WorkspacePendingTerminalInputObserver` box); `onReady` is invoked once,
    /// on the main actor, when the surface fires its ready notification, and the
    /// coordinator is responsible for cancelling the handle.
    ///
    /// Returns `nil` only when the panel cannot be resolved to register against;
    /// the legacy code always had a live `panel` here, so production conformers
    /// return a non-`nil` handle.
    func observeTerminalSurfaceReady(
        forPanelId panelId: UUID,
        onReady: @escaping @MainActor () -> Void
    ) -> (any PendingTerminalInputObservation)?
}
