import Bonsplit
import Foundation

extension Workspace {
    /// Returns the display-only title presentation for one terminal panel.
    func codexTabTitlePresentation(
        panelId: UUID,
        fallback: String? = nil
    ) -> CodexTabTitlePresentation {
        let panel = panels[panelId]
        let baseTitle = fallback
            ?? panelTitles[panelId]
            ?? panel?.displayTitle
            ?? "Tab"
        return CodexTabTitleComposer.presentation(
            baseTitle: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            lifecycle: agentLifecycleStatesByPanelId[panelId]?[CodexTabTitleComposer.statusKey],
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
    }

    /// Reconciles the Bonsplit tab's transient Codex title presentation.
    func refreshCodexTabTitle(panelId: UUID) {
        guard !isRemoteTmuxMirror,
              panels[panelId] is TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else {
            return
        }
        let presentation = codexTabTitlePresentation(panelId: panelId)
        let titleUpdate: String? = existing.title == presentation.title ? nil : presentation.title
        let animationUpdate: Bool? = existing.isLoading == presentation.isAnimating
            ? nil
            : presentation.isAnimating
        guard titleUpdate != nil || animationUpdate != nil else { return }
        bonsplitController.updateTab(
            tabId,
            title: titleUpdate,
            isLoading: animationUpdate
        )
    }

    /// Reconciles every terminal tab after a restored runtime snapshot lands.
    func refreshCodexTabTitles() {
        for panelId in panels.keys {
            refreshCodexTabTitle(panelId: panelId)
        }
    }
}
