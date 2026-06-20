public import Foundation

/// DEBUG-only reactGrab-pasteback tracing seam for the
/// ``TerminalTextSendCoordinator``.
///
/// The legacy `AppDelegate.sendTextWhenReady` emitted dense `cmuxDebugLog`
/// `reactGrab.pasteback h2.*` / `h1.*` lines, only when a `preferredPanelId` was
/// present (i.e. the reactGrab pasteback flow). Those lines reference the app's
/// `cmuxDebugLog` sink, `Self.debugShortId`, and live `Workspace` state
/// (`focusedPanelId`, `focusedTerminalPanel`), none of which can move into the
/// package. The coordinator calls these hooks at the same points the legacy body
/// logged; the app-side conformer holds the workspace, reads that live state, and
/// formats the identical strings inside `#if DEBUG`, so DEBUG-build trace output
/// is byte-identical. In release builds the app injects nil and the coordinator
/// skips every call.
///
/// The coordinator passes only the values it computes (resolved panel,
/// surface-readiness, the resolved latch, the signal's surface id, text length);
/// the conformer supplies workspace-derived fields (`focusedPanelId`,
/// `focusedTerminalPanel.id`) from its retained workspace reference.
@MainActor
public protocol TerminalTextSendTracing: AnyObject {
    /// `h2.send.start`: emitted once at entry, with the initially-resolved target.
    func sendStart(
        preferredPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        textCount: Int
    )

    /// `h2.send.immediate`: emitted before an immediate (surface-ready) send.
    func sendImmediate(targetPanelID: UUID, textCount: Int)

    /// `h2.send.sent`: emitted after a successful send. `delayed` distinguishes
    /// the immediate path (false) from the observer-driven path (true).
    func sendSent(targetPanelID: UUID, delayed: Bool, textCount: Int)

    /// `h2.finishIfReady`: emitted at the top of each readiness re-check.
    func finishIfReady(
        preferredPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        alreadyResolved: Bool
    )

    /// `h2.panelsChanged`: emitted on each panels-set change.
    func panelsChanged()

    /// `h2.surfaceReadyEvent`: emitted on each surface-ready signal.
    func surfaceReadyEvent(surfaceID: UUID?, preferredPanelID: UUID?)

    /// `h2.send.timeout`: emitted when the 3s timeout fires before resolution.
    func sendTimeout(preferredPanelID: UUID?)

    /// `h1.focusEvent`: emitted on each ghostty focus signal.
    func focusEvent(surfaceID: UUID, preferredPanelID: UUID?)

    /// `h1.firstResponderEvent`: emitted on each ghostty first-responder signal.
    func firstResponderEvent(surfaceID: UUID, preferredPanelID: UUID?)
}
