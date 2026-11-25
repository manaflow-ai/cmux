public import CmuxNextActions
import CmuxNextDesign

extension BackdropSelectionSetting {
    /// Follow Desktop Wallpaper (`appearance.background.followDesktop`).
    public static let followDesktopAction: ActionID = "appearance.background.followDesktop"

    /// Binds Follow Desktop Wallpaper: one click from the palette or the window's (or a chat's)
    /// empty-space menu writes `appearance.background: "desktop"`, so the window mirrors the macOS
    /// desktop picture of its screen and follows each change of it; the cmux.json watcher applies
    /// it, as for every other background. Its row is checked while `follows()` (the background is
    /// the desktop already).
    /// - Parameters:
    ///   - registry: Where the action is bound.
    ///   - save: Writes the setting (refused when it is managed).
    ///   - follows: Whether the background follows the desktop now.
    @MainActor public static func bindFollowDesktop(into registry: ActionRegistry, save: @escaping SettingChoiceActions.Save,
                                                   follows: @escaping @MainActor () -> Bool) {
        SettingChoiceActions.bind([BackdropSelection.desktopID], into: registry, id: { _ in followDesktopAction.rawValue },
                                  path: configPath, fileValue: { .string($0) }, save: save) { _ in }
        ActionTargetTitles.setPaletteState(followDesktopAction, in: registry, follows)
        ActionTargetTitles.setState(followDesktopAction, in: registry) { _ in follows() }
    }
}
