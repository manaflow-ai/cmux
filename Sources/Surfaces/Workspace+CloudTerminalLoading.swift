import Bonsplit
import Foundation

extension Workspace {
    /// Ends the Cloud workspace handoff after the first presented frame of the
    /// replacement terminal, keeping the loader over blank runtime surfaces.
    @MainActor
    func beginCloudTerminalStartupLoading(panel: TerminalPanel, tabID: TabID) {
        let setLoading: @MainActor (Bool) -> Void = { [weak self, weak panel] loading in
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
                isLoading: loading,
                isPinned: nil
            )
        }
        panel.cloudStartupReadiness.begin(
            surface: panel.surface,
            condition: { [weak panel] in
                guard let panel else { return false }
                if let attachment = panel.cloudAttachment {
                    return attachment.state == .attached
                }
                return panel.surface.hasLiveSurface && panel.surface.isRendererEffectivelyVisible
            },
            onReady: { setLoading(false) },
            onEnded: { setLoading(false) },
            onTimedOut: { [weak self, weak panel] in
                guard let self, let panel,
                      self.panels[panel.id] != nil else { return }
                self.setCloudMaterializationFailure(
                    surfaceID: panel.id,
                    detail: String(
                        localized: "cloud.overlay.renderTimedOut.detail",
                        defaultValue: "The Cloud terminal connected but did not present a visible frame. Reconnect and try again."
                    ),
                    reference: nil
                )
            }
        )
    }
}
