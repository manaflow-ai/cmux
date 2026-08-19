import Foundation
import CmuxTerminalCore

extension Workspace {
    /// Builds the pure composer with the host-localized marker strings.
    private func codexTabTitleComposer() -> CodexTabTitleComposer {
        CodexTabTitleComposer(
            runningMarker: String(
                localized: "tab.codex.runningMarker",
                defaultValue: "◐ "
            ),
            idleMarker: String(
                localized: "tab.codex.idleMarker",
                defaultValue: "✳ "
            )
        )
    }

    private func codexTabLifecycle(panelId: UUID) -> CodexTabTitleLifecycle? {
        guard let raw = agentLifecycleStatesByPanelId[panelId]?[
            "codex"
        ] else {
            return nil
        }
        switch raw {
        case .running: return .running
        case .idle: return .idle
        case .needsInput: return .needsInput
        case .unknown: return .unknown
        }
    }

    private func panelTitleIsUserOwned(_ panelId: UUID) -> Bool {
        guard panelCustomTitles[panelId] != nil else { return false }
        return (panelCustomTitleSources[panelId] ?? .user) == .user
    }

    /// Reconciles one Bonsplit tab's title and loading presentation.
    ///
    /// This is the single tab-projection owner for terminal title, lifecycle,
    /// restore, binding, and transfer callers. Stable panel/workspace state is
    /// never written with the transient marker.
    @discardableResult
    func reconcileTabTitlePresentation(
        panelId: UUID,
        fallback: String? = nil
    ) -> Bool {
        guard let panel = panels[panelId],
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else {
            return false
        }

        let baseTitle = fallback
            ?? panelTitles[panelId]
            ?? panel.displayTitle
        let resolvedBaseTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
        let isTerminal = panel is TerminalPanel
        let presentation: CodexTabTitlePresentation
        if isTerminal, !isRemoteTmuxMirror {
            presentation = codexTabTitleComposer().presentation(
                baseTitle: resolvedBaseTitle,
                lifecycle: codexTabLifecycle(panelId: panelId),
                hasUserOwnedTitle: panelTitleIsUserOwned(panelId)
            )
        } else {
            presentation = CodexTabTitlePresentation(
                title: resolvedBaseTitle,
                isAnimating: false
            )
        }

        let titleUpdate: String? = existing.title == presentation.title ? nil : presentation.title
        let animationUpdate: Bool? = isTerminal && !isRemoteTmuxMirror
            ? (existing.isLoading == presentation.isAnimating ? nil : presentation.isAnimating)
            : nil
        let customTitle = panelCustomTitles[panelId] != nil
        let customTitleUpdate: Bool? = existing.hasCustomTitle == customTitle ? nil : customTitle
        guard titleUpdate != nil || animationUpdate != nil || customTitleUpdate != nil else {
            return false
        }
        bonsplitController.updateTab(
            tabId,
            title: titleUpdate,
            isLoading: animationUpdate,
            hasCustomTitle: customTitleUpdate
        )
        return true
    }

}
