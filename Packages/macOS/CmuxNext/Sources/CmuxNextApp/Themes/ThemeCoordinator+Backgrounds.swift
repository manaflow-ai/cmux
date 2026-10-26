import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Each workspace's own background (cx-t2x.5). The window's backdrop reads its room scope, so the
/// room scope takes the shown workspace's pick; a workspace without one follows the app's
/// `appearance.background`.
extension ThemeCoordinator {
    /// Gives `content`'s scope its background; its window's room shows it while it is shown.
    func applyWorkspaceBackground(_ content: WorkspaceContentController) {
        content.themeScope.pinBackdrop(workspaceBackgroundPin(content.workspace.id))
        content.themeScope.pinBackdropTint(workspaceOpacity(content.workspace.id))
    }

    /// A workspace's own tint over art: the slider's preview, else the saved one.
    func workspaceOpacity(_ workspaceID: String) -> Double? {
        if let opacityPreview, opacityPreview.workspace == workspaceID { return opacityPreview.value }
        return workspaceBackgroundKey(workspaceID).flatMap(workspaceOpacities.background(for:))
            .flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Saves a workspace's own tint over art (nil follows the work's) and ends its preview.
    func setWorkspaceOpacity(_ opacity: Double?, for workspaceID: String) {
        opacityPreview = nil
        guard let key = workspaceBackgroundKey(workspaceID) else { return }
        workspaceOpacities.set(opacity.map { String(min(max($0, 0), WindowBackdrop.maximumWorkspaceTint)) }, for: key)
        apply()
    }

    /// Shows a tint for the workspace without saving it (the slider moving); nil ends the preview.
    func previewWorkspaceOpacity(_ opacity: Double??, for workspaceID: String) {
        opacityPreview = opacity.map { (workspaceID, $0) }
        apply()
    }

    /// Re-applies on a new day (or a clock or time zone change), so a Shuffle Daily workspace
    /// shows that day's work, like `appearance.background`'s own timer. The app's one observer per
    /// notice (`AppServices.appEvents`) calls it in the notice's turn.
    func observeDayChanges() -> [EventSubscription] {
        [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange].map { name in
            services.appEvents.subscribe(name, owner: "ThemeCoordinator.dayChange") { [weak self] in
                guard let self, [workspaceBackgrounds, appearanceScopes].contains(where: { $0.backgrounds.values.contains(where: BackdropSelectionSetting.shuffles) }) else { return }
                apply()
            }
        }
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
