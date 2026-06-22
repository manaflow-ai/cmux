#if DEBUG
import CmuxNotifications
import Foundation

/// DEBUG-only app-side ``TerminalTextSendTracing`` conformer. Holds the workspace
/// so it can read live `focusedPanelId`/`focusedTerminalPanel` state at emit time,
/// then hands those values plus the coordinator-supplied values to the package
/// ``TerminalTextSendTraceLine`` formatter (which owns the byte-exact line shape,
/// the `shortId` abbreviation, and the `match=` computation) and forwards the
/// formatted line to the `cmuxDebugLog` sink. Only constructed when a
/// `preferredPanelID` is present (the reactGrab pasteback flow), matching the
/// legacy `isReactGrabPasteback` gate. DEBUG trace output is byte-identical to the
/// former inline body.
@MainActor
final class TerminalTextSendTracer: TerminalTextSendTracing {
    private let tab: Tab
    private let line: TerminalTextSendTraceLine

    init(tab: Tab) {
        self.tab = tab
        self.line = TerminalTextSendTraceLine(workspaceID: tab.id)
    }

    func sendStart(
        preferredPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        textCount: Int
    ) {
        cmuxDebugLog(line.sendStart(
            preferredPanelID: preferredPanelID,
            focusedPanelID: tab.focusedPanelId,
            focusedTerminalPanelID: tab.focusedTerminalPanel?.id,
            resolvedPanelID: resolvedPanelID,
            surfaceReady: surfaceReady,
            textCount: textCount
        ))
    }

    func sendImmediate(targetPanelID: UUID, textCount: Int) {
        cmuxDebugLog(line.sendImmediate(targetPanelID: targetPanelID, textCount: textCount))
    }

    func sendSent(targetPanelID: UUID, delayed: Bool, textCount: Int) {
        cmuxDebugLog(line.sendSent(targetPanelID: targetPanelID, delayed: delayed, textCount: textCount))
    }

    func finishIfReady(
        preferredPanelID: UUID?,
        resolvedPanelID: UUID?,
        surfaceReady: Bool,
        alreadyResolved: Bool
    ) {
        cmuxDebugLog(line.finishIfReady(
            preferredPanelID: preferredPanelID,
            focusedPanelID: tab.focusedPanelId,
            resolvedPanelID: resolvedPanelID,
            surfaceReady: surfaceReady,
            alreadyResolved: alreadyResolved
        ))
    }

    func panelsChanged() {
        cmuxDebugLog(line.panelsChanged(focusedPanelID: tab.focusedPanelId))
    }

    func surfaceReadyEvent(surfaceID: UUID?, preferredPanelID: UUID?) {
        cmuxDebugLog(line.surfaceReadyEvent(surfaceID: surfaceID, preferredPanelID: preferredPanelID))
    }

    func sendTimeout(preferredPanelID: UUID?) {
        cmuxDebugLog(line.sendTimeout(
            preferredPanelID: preferredPanelID,
            focusedPanelID: tab.focusedPanelId,
            focusedTerminalPanelID: tab.focusedTerminalPanel?.id
        ))
    }

    func focusEvent(surfaceID: UUID, preferredPanelID: UUID?) {
        cmuxDebugLog(line.focusEvent(surfaceID: surfaceID, preferredPanelID: preferredPanelID))
    }

    func firstResponderEvent(surfaceID: UUID, preferredPanelID: UUID?) {
        cmuxDebugLog(line.firstResponderEvent(surfaceID: surfaceID, preferredPanelID: preferredPanelID))
    }
}
#endif
