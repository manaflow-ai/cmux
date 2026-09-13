import Foundation

extension Workspace {
    /// Ends the Cloud workspace handoff after the first presented frame of the
    /// replacement terminal, keeping the loader over blank runtime surfaces.
    @MainActor
    func beginCloudTerminalStartupLoading(panel: TerminalPanel, tabID: UUID) {
        panel.cloudStartupReadiness.begin(
            surface: panel.surface,
            condition: { panel.surface.hasLiveSurface && panel.surface.isRendererEffectivelyVisible },
            onReady: { [weak self, weak panel] in
                guard let self, let panel,
                      let current = self.panels[panel.id] as? TerminalPanel,
                      current === panel else { return }
                self.bonsplitController.updateTab(
                    tabID,
                    title: nil,
                    icon: nil,
                    iconImageData: nil,
                    iconAsset: nil,
                    kind: nil,
                    hasCustomTitle: nil,
                    isDirty: nil,
                    showsNotificationBadge: nil,
                    isLoading: false,
                    isPinned: nil
                )
            }
        )
    }
}
