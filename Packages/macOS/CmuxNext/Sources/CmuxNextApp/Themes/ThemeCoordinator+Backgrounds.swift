import CmuxNextDesign
import Foundation

/// Each workspace's own background (cx-t2x.5). The window's backdrop reads its room scope, so the
/// room scope takes the shown workspace's pick; a workspace without one follows the app's
/// `appearance.background`.
extension ThemeCoordinator {
    /// Shows `content`'s background in its window, when it is the shown workspace.
    func applyWorkspaceBackground(_ content: WorkspaceContentController) {
        guard let window = services.windows.controllers.first(where: { $0.content === content }) else { return }
        window.themeScope.pinBackdrop(workspaceBackgroundPin(content.workspace.id))
    }

    /// The store key of a workspace: its home session and durable key.
    func workspaceBackgroundKey(_ workspaceID: String) -> String? {
        WindowProfiles.qualified(workspaceID, machines: services.machines)
            .map { WorkspaceBackgroundStore.key(session: $0.session, workspace: $0.key) }
    }

    /// A workspace's own background: the picker's preview, else the saved one.
    func workspaceBackground(_ workspaceID: String) -> String? {
        if let backgroundPreview, backgroundPreview.workspace == workspaceID { return backgroundPreview.value }
        return workspaceBackgroundKey(workspaceID).flatMap(workspaceBackgrounds.background(for:))
    }

    func workspaceBackgroundPin(_ workspaceID: String) -> BackdropPin {
        WorkspaceBackgroundStore.pin(workspaceBackground(workspaceID), now: Date())
    }

    /// Saves a workspace's own background (nil follows the app's) and ends its preview.
    func setWorkspaceBackground(_ background: String?, for workspaceID: String) {
        backgroundPreview = nil
        guard let key = workspaceBackgroundKey(workspaceID) else { return }
        workspaceBackgrounds.set(background, for: key)
        apply()
    }

    /// Shows `background` for the workspace without saving it (the picker resting on a tile);
    /// nil ends the preview.
    func previewWorkspaceBackground(_ background: String??, for workspaceID: String) {
        backgroundPreview = background.map { (workspaceID, $0) }
        apply()
    }
}
