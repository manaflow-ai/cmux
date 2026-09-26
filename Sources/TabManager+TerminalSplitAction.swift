import Bonsplit
import CmuxPanes
import Foundation

/// Preserves asynchronous acceptance through the shared terminal split action.
@MainActor
extension TabManager {
    func createSplitOutcome(direction: SplitDirection) -> TerminalPanelCreationOutcome {
        guard let selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedTabId }),
              let panelID = workspace.focusedPanelId else { return .failed }
        return createSplitOutcome(tabId: selectedTabId, surfaceId: panelID, direction: direction)
    }

    func createSplitOutcome(
        tabId: UUID,
        surfaceId: UUID,
        direction: SplitDirection,
        focus: Bool = true
    ) -> TerminalPanelCreationOutcome {
        guard let workspace = tabs.first(where: { $0.id == tabId }),
              workspace.panels[surfaceId] != nil else { return .failed }
        workspace.clearSplitZoom()
        sentryBreadcrumb("split.create", data: ["direction": String(describing: direction)])
        let outcome = workspace.newTerminalSplitOutcome(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus
        )
        if let panel = outcome.panel {
            workspace.equalizeSplitsAfterCreatingSplitIfEnabled(newPanelId: panel.id)
        }
        return outcome
    }
}
