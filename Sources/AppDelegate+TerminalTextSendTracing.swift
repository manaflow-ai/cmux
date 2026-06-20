#if DEBUG
import CmuxNotifications
import Foundation

/// DEBUG-only app-side ``TerminalTextSendTracing`` conformer. Holds the workspace
/// so it can read live `focusedPanelId`/`focusedTerminalPanel` state, and emits
/// the byte-identical `cmuxDebugLog` `reactGrab.pasteback h*.*` lines the legacy
/// inline `sendTextWhenReady` body produced. Only constructed when a
/// `preferredPanelID` is present (the reactGrab pasteback flow), matching the
/// legacy `isReactGrabPasteback` gate.
@MainActor
final class TerminalTextSendTracer: TerminalTextSendTracing {
    private let tab: Tab

    init(tab: Tab) {
        self.tab = tab
    }

    private func shortId(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    func sendStart(
        preferredPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        textCount: Int
    ) {
        cmuxDebugLog(
            "reactGrab.pasteback h2.send.start " +
            "workspace=\(shortId(tab.id)) " +
            "preferred=\(shortId(preferredPanelID)) " +
            "focused=\(shortId(tab.focusedPanelId)) " +
            "focusedTerminal=\(shortId(tab.focusedTerminalPanel?.id)) " +
            "resolved=\(shortId(resolvedPanelID)) " +
            "surfaceReady=\(surfaceReady ? 1 : 0) len=\(textCount)"
        )
    }

    func sendImmediate(targetPanelID: UUID, textCount: Int) {
        cmuxDebugLog(
            "reactGrab.pasteback h2.send.immediate " +
            "workspace=\(shortId(tab.id)) " +
            "target=\(shortId(targetPanelID)) len=\(textCount)"
        )
    }

    func sendSent(targetPanelID: UUID, delayed: Bool, textCount: Int) {
        cmuxDebugLog(
            "reactGrab.pasteback h2.send.sent " +
            "workspace=\(shortId(tab.id)) " +
            "target=\(shortId(targetPanelID)) mode=\(delayed ? "delayed" : "immediate") len=\(textCount)"
        )
    }

    func finishIfReady(
        preferredPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        alreadyResolved: Bool
    ) {
        cmuxDebugLog(
            "reactGrab.pasteback h2.finishIfReady " +
            "workspace=\(shortId(tab.id)) " +
            "preferred=\(shortId(preferredPanelID)) " +
            "focused=\(shortId(tab.focusedPanelId)) " +
            "resolved=\(shortId(resolvedPanelID)) " +
            "surfaceReady=\(surfaceReady ? 1 : 0) alreadyResolved=\(alreadyResolved ? 1 : 0)"
        )
    }

    func panelsChanged() {
        cmuxDebugLog(
            "reactGrab.pasteback h2.panelsChanged " +
            "workspace=\(shortId(tab.id)) " +
            "focused=\(shortId(tab.focusedPanelId))"
        )
    }

    func surfaceReadyEvent(surfaceID: UUID?, preferredPanelID: UUID?) {
        cmuxDebugLog(
            "reactGrab.pasteback h2.surfaceReadyEvent " +
            "workspace=\(shortId(tab.id)) " +
            "surface=\(shortId(surfaceID)) " +
            "target=\(shortId(preferredPanelID)) " +
            "match=\(surfaceID == preferredPanelID ? 1 : 0)"
        )
    }

    func sendTimeout(preferredPanelID: UUID?) {
        cmuxDebugLog(
            "reactGrab.pasteback h2.send.timeout " +
            "workspace=\(shortId(tab.id)) " +
            "preferred=\(shortId(preferredPanelID)) " +
            "focused=\(shortId(tab.focusedPanelId)) " +
            "focusedTerminal=\(shortId(tab.focusedTerminalPanel?.id))"
        )
    }

    func focusEvent(surfaceID: UUID, preferredPanelID: UUID?) {
        cmuxDebugLog(
            "reactGrab.pasteback h1.focusEvent " +
            "workspace=\(shortId(tab.id)) " +
            "surface=\(shortId(surfaceID)) " +
            "target=\(shortId(preferredPanelID)) " +
            "match=\(surfaceID == preferredPanelID ? 1 : 0)"
        )
    }

    func firstResponderEvent(surfaceID: UUID, preferredPanelID: UUID?) {
        cmuxDebugLog(
            "reactGrab.pasteback h1.firstResponderEvent " +
            "workspace=\(shortId(tab.id)) " +
            "surface=\(shortId(surfaceID)) " +
            "target=\(shortId(preferredPanelID)) " +
            "match=\(surfaceID == preferredPanelID ? 1 : 0)"
        )
    }
}
#endif
