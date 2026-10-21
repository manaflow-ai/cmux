import AppKit
import CmuxNextActions
import CmuxNextHome

/// Home's first-run "Switching" card for the app: the keys from the live
/// binding table, whether the person hid the card (kept on this Mac), and
/// whether Mission Control's Switch to Desktop takes the tabs-by-number keys.
///
/// The defaults and the symbolic hot keys reader are injected, so tests
/// never read the user's preferences.
@MainActor
final class HomeSwitchKeysSource {
    static let hiddenKey = "home.firstRun.switchKeysHidden"
    /// System Settings > Keyboard > Keyboard Shortcuts (macOS 13 and later).
    static let keyboardShortcutsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
    private let defaults: UserDefaults
    private let symbolicHotKeys: () -> [String: Any]?

    /// - Parameters:
    ///   - defaults: Where Hide is kept (the app's defaults).
    ///   - symbolicHotKeys: Reads `com.apple.symbolichotkeys` `AppleSymbolicHotKeys`; nil when absent.
    init(defaults: UserDefaults = .standard, symbolicHotKeys: @escaping () -> [String: Any]? = HomeSwitchKeysSource.readSymbolicHotKeys) {
        self.defaults = defaults
        self.symbolicHotKeys = symbolicHotKeys
    }

    /// The person hid the card with its Hide button.
    var isHidden: Bool { defaults.bool(forKey: Self.hiddenKey) }

    func hide() { defaults.set(true, forKey: Self.hiddenKey) }

    /// The card's content from `registry`, or nil once hidden.
    func keys(registry: ActionRegistry) -> HomeSwitchKeys? {
        guard !isHidden else { return nil }
        let live = SwitchingShortcuts(registry: registry)
        let conflict = live.tabByNumberModifiers.map {
            MissionControlDesktopKeys(symbolicHotKeys: symbolicHotKeys()).conflicts(withDigitModifiers: $0)
        } ?? false
        return HomeSwitchKeys(tabByNumber: live.tabByNumber, workspaceByNumber: live.workspaceByNumber,
                              nextPreviousTab: live.nextPreviousTab, nextPreviousWorkspace: live.nextPreviousWorkspace,
                              focusBackForward: live.focusBackForward, desktopConflict: conflict)
    }

    /// The current user's `AppleSymbolicHotKeys` (another app's preferences; read only).
    nonisolated static func readSymbolicHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue(MissionControlDesktopKeys.preferencesKey as CFString,
                                  MissionControlDesktopKeys.preferencesDomain as CFString) as? [String: Any]
    }
}
