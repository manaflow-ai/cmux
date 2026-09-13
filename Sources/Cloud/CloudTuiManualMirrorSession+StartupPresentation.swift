import Foundation

@MainActor
extension CloudTuiManualMirrorSession {
    /// Clears the Bonsplit loading bit when this attachment is retired. The
    /// inline reconnect presentation remains responsible for explaining the
    /// transient failure.
    func clearStartupLoading() {
        guard let surface,
              let workspace = surface.owningWorkspace(),
              let tabID = workspace.surfaceIdFromPanelId(surface.id) else { return }
        workspace.bonsplitController.updateTab(
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
}
