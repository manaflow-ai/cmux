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

    /// Adds a terminal pane from the focused panel and arranges the
    /// workspace in Zellij's default tiling, the cmux-tui Alt-n behavior.
    /// Remote tmux mirrors and Cloud panes keep their own layout owner, so
    /// they receive an ordinary split right.
    func createAutoLayoutPaneOutcome(
        tabId: UUID,
        surfaceId: UUID,
        focus: Bool = true
    ) -> TerminalPanelCreationOutcome {
        guard let workspace = tabs.first(where: { $0.id == tabId }),
              workspace.panels[surfaceId] != nil else { return .failed }
        sentryBreadcrumb("split.create", data: ["direction": "autoLayout"])
        return workspace.newTerminalSplitOutcome(
            from: surfaceId,
            orientation: .horizontal,
            focus: focus,
            autoLayout: true
        )
    }

    func createAutoLayoutPaneOutcome() -> TerminalPanelCreationOutcome {
        guard let selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedTabId }),
              let panelID = workspace.focusedPanelId else { return .failed }
        return createAutoLayoutPaneOutcome(tabId: selectedTabId, surfaceId: panelID)
    }
}
