public import Foundation

/// Owns the byte-exact `cmuxDebugLog` line format for the DEBUG reactGrab
/// pasteback trace emitted by ``TerminalTextSendCoordinator``.
///
/// The legacy `AppDelegate.sendTextWhenReady` body, and the app-side
/// ``TerminalTextSendTracing`` conformer that first replaced it, both inlined the
/// `reactGrab.pasteback h1.*` / `h2.*` format strings, the 5-char `shortId`
/// abbreviation, and the `match=` equality computation. That string-shape is a
/// decision, not a live-state read: it depends only on the values the coordinator
/// computes (`preferredPanelID`, the resolved panel id, surface readiness, the
/// resolved latch, the signal surface id, text length) plus the workspace-derived
/// fields the conformer reads from live `Workspace` state
/// (`focusedPanelId`, `focusedTerminalPanel.id`). This type lifts the decision
/// into the package: each method returns the fully-formatted line, so the
/// conformer's only remaining job is to read the live `Workspace` fields and hand
/// the resulting line to its `cmuxDebugLog` sink. The output is byte-identical to
/// the former inline body.
///
/// A value type, not a static namespace: it is constructed with the workspace
/// identity it traces (the constant `workspace=` prefix every line carries), so
/// the conformer holds one instance per send flow rather than threading the id
/// through every call.
public struct TerminalTextSendTraceLine: Sendable {
    private let workspaceID: UUID

    /// Creates a formatter bound to `workspaceID`, the workspace whose pasteback
    /// flow is being traced. Every produced line carries `workspace=<shortId>`.
    public init(workspaceID: UUID) {
        self.workspaceID = workspaceID
    }

    /// The legacy 5-character id abbreviation (`String(uuid.prefix(5))`, `"nil"`
    /// for a missing id) used in every trace field.
    private func shortID(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    /// `h2.send.start`: emitted once at entry, with the initially-resolved target.
    public func sendStart(
        preferredPanelID: UUID?,
        focusedPanelID: UUID?,
        focusedTerminalPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        textCount: Int
    ) -> String {
        "reactGrab.pasteback h2.send.start " +
        "workspace=\(shortID(workspaceID)) " +
        "preferred=\(shortID(preferredPanelID)) " +
        "focused=\(shortID(focusedPanelID)) " +
        "focusedTerminal=\(shortID(focusedTerminalPanelID)) " +
        "resolved=\(shortID(resolvedPanelID)) " +
        "surfaceReady=\(surfaceReady ? 1 : 0) len=\(textCount)"
    }

    /// `h2.send.immediate`: emitted before an immediate (surface-ready) send.
    public func sendImmediate(targetPanelID: UUID, textCount: Int) -> String {
        "reactGrab.pasteback h2.send.immediate " +
        "workspace=\(shortID(workspaceID)) " +
        "target=\(shortID(targetPanelID)) len=\(textCount)"
    }

    /// `h2.send.sent`: emitted after a successful send. `delayed` distinguishes
    /// the immediate path (false) from the observer-driven path (true).
    public func sendSent(targetPanelID: UUID, delayed: Bool, textCount: Int) -> String {
        "reactGrab.pasteback h2.send.sent " +
        "workspace=\(shortID(workspaceID)) " +
        "target=\(shortID(targetPanelID)) mode=\(delayed ? "delayed" : "immediate") len=\(textCount)"
    }

    /// `h2.finishIfReady`: emitted at the top of each readiness re-check.
    public func finishIfReady(
        preferredPanelID: UUID?,
        focusedPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        alreadyResolved: Bool
    ) -> String {
        "reactGrab.pasteback h2.finishIfReady " +
        "workspace=\(shortID(workspaceID)) " +
        "preferred=\(shortID(preferredPanelID)) " +
        "focused=\(shortID(focusedPanelID)) " +
        "resolved=\(shortID(resolvedPanelID)) " +
        "surfaceReady=\(surfaceReady ? 1 : 0) alreadyResolved=\(alreadyResolved ? 1 : 0)"
    }

    /// `h2.panelsChanged`: emitted on each panels-set change.
    public func panelsChanged(focusedPanelID: UUID?) -> String {
        "reactGrab.pasteback h2.panelsChanged " +
        "workspace=\(shortID(workspaceID)) " +
        "focused=\(shortID(focusedPanelID))"
    }

    /// `h2.surfaceReadyEvent`: emitted on each surface-ready signal.
    public func surfaceReadyEvent(surfaceID: UUID?, preferredPanelID: UUID?) -> String {
        "reactGrab.pasteback h2.surfaceReadyEvent " +
        "workspace=\(shortID(workspaceID)) " +
        "surface=\(shortID(surfaceID)) " +
        "target=\(shortID(preferredPanelID)) " +
        "match=\(surfaceID == preferredPanelID ? 1 : 0)"
    }

    /// `h2.send.timeout`: emitted when the 3s timeout fires before resolution.
    public func sendTimeout(
        preferredPanelID: UUID?,
        focusedPanelID: UUID?,
        focusedTerminalPanelID: UUID?
    ) -> String {
        "reactGrab.pasteback h2.send.timeout " +
        "workspace=\(shortID(workspaceID)) " +
        "preferred=\(shortID(preferredPanelID)) " +
        "focused=\(shortID(focusedPanelID)) " +
        "focusedTerminal=\(shortID(focusedTerminalPanelID))"
    }

    /// `h1.focusEvent`: emitted on each ghostty focus signal.
    public func focusEvent(surfaceID: UUID, preferredPanelID: UUID?) -> String {
        "reactGrab.pasteback h1.focusEvent " +
        "workspace=\(shortID(workspaceID)) " +
        "surface=\(shortID(surfaceID)) " +
        "target=\(shortID(preferredPanelID)) " +
        "match=\(surfaceID == preferredPanelID ? 1 : 0)"
    }

    /// `h1.firstResponderEvent`: emitted on each ghostty first-responder signal.
    public func firstResponderEvent(surfaceID: UUID, preferredPanelID: UUID?) -> String {
        "reactGrab.pasteback h1.firstResponderEvent " +
        "workspace=\(shortID(workspaceID)) " +
        "surface=\(shortID(surfaceID)) " +
        "target=\(shortID(preferredPanelID)) " +
        "match=\(surfaceID == preferredPanelID ? 1 : 0)"
    }
}
