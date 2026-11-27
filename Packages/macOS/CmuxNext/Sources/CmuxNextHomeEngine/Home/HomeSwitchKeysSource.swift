package import AppKit
package import CmuxNextActions
package import CmuxNextHomeModel

/// Home's first-run "Switching" card for the app: the keys from the live
/// binding table, whether the person hid the card (kept on this Mac), and
/// whether Mission Control's Switch to Desktop takes the tabs-by-number keys.
///
/// The defaults and the symbolic hot keys reader are injected, so tests
/// never read the user's preferences.
@MainActor
package final class HomeSwitchKeysSource {
    package static let hiddenKey = "home.firstRun.switchKeysHidden"
    /// System Settings > Keyboard > Keyboard Shortcuts (macOS 13 and later).
    package static let keyboardShortcutsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
    private let defaults: UserDefaults
    private let symbolicHotKeys: () -> [String: Any]?

    /// - Parameters:
    ///   - defaults: Where Hide is kept (the app's defaults).
    ///   - symbolicHotKeys: Reads `com.apple.symbolichotkeys` `AppleSymbolicHotKeys`; nil when absent.
    package init(defaults: UserDefaults = .standard, symbolicHotKeys: @escaping () -> [String: Any]? = HomeSwitchKeysSource.readSymbolicHotKeys) {
        self.defaults = defaults
        self.symbolicHotKeys = symbolicHotKeys
    }

    /// The person hid the card with its Hide button.
    package var isHidden: Bool { defaults.bool(forKey: Self.hiddenKey) }

    package func hide() { defaults.set(true, forKey: Self.hiddenKey) }

    /// The card's content from `registry`, or nil once hidden (`welcome.switchKeys`). Mission Control's
    /// keys are read only when the card shows and the tabs-by-number keys are bound.
    package func keys(registry: ActionRegistry) -> HomeSwitchKeys? {
        let hidden = isHidden
        let live = SwitchingShortcuts(registry: registry)
        let conflicts = hidden ? false : live.tabByNumberModifiers.map {
            MissionControlDesktopKeys(symbolicHotKeys: symbolicHotKeys()).conflicts(withDigitModifiers: $0)
        } ?? false
        let input = SwitchKeysInput(hidden: hidden, hasTabByNumberModifiers: live.tabByNumberModifiers != nil, missionControlConflicts: conflicts)
        let reply: SwitchKeysReply = welcomeRule("welcome.switchKeys", input, fallback: SwitchKeysReply(shows: false, desktopConflict: false))
        guard reply.shows else { return nil }
        return HomeSwitchKeys(tabByNumber: live.tabByNumber, workspaceByNumber: live.workspaceByNumber,
                              nextPreviousTab: live.nextPreviousTab, nextPreviousWorkspace: live.nextPreviousWorkspace,
                              focusBackForward: live.focusBackForward, desktopConflict: reply.desktopConflict)
    }

    /// The current user's `AppleSymbolicHotKeys` (another app's preferences; read only).
    package nonisolated static func readSymbolicHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue(MissionControlDesktopKeys.preferencesKey as CFString,
                                  MissionControlDesktopKeys.preferencesDomain as CFString) as? [String: Any]
    }
}

// The Switching card op's wire shapes (cmux-home-rules `welcome/intro.rs`).
private nonisolated struct SwitchKeysInput: Encodable {
    var hidden: Bool
    var hasTabByNumberModifiers: Bool
    var missionControlConflicts: Bool
}

private nonisolated struct SwitchKeysReply: Decodable {
    var shows: Bool
    var desktopConflict: Bool
}
