import Foundation

/// Device-local preferences read below `CmuxMobileModel` (the terminal, code cards,
/// diffs, the agent composer). Settings writes them through `SettingsStore`
/// under these same `UserDefaults` keys; SwiftUI views read them with
/// `@AppStorage(CmuxMobilePreferences.Key...)` so a change applies at once.
public enum CmuxMobilePreferences {
    public enum Key {
        public static let terminalFontSize = "cmuxMobile.settings.terminalFontSize"
        public static let wrapCode = "cmuxMobile.settings.wrapCode"
        public static let keyClicks = "cmuxMobile.settings.keyClicks"
        public static let dismissKeyboardAfterSend = "cmuxMobile.settings.dismissKeyboardAfterSend"
        public static let followUp = "cmuxMobile.settings.followUp"
    }

    /// The terminal's font size in points when the person never changed it.
    public static let defaultTerminalFontSize = 12
    /// The sizes Settings offers (and the terminal accepts).
    public static let terminalFontSizes = 9...24
    public static let defaultWrapCode = false
    public static let defaultKeyClicks = true
    public static let defaultDismissKeyboardAfterSend = true
    /// `FollowUpBehavior.steer.rawValue`: a message sent while the agent works
    /// interrupts it instead of waiting for the turn to end.
    public static let steerFollowUp = "steer"

    public static func terminalFontSize(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: Key.terminalFontSize) as? Int ?? defaultTerminalFontSize
        return min(max(stored, terminalFontSizes.lowerBound), terminalFontSizes.upperBound)
    }

    public static func wrapCode(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.wrapCode) as? Bool ?? defaultWrapCode
    }

    public static func keyClicks(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.keyClicks) as? Bool ?? defaultKeyClicks
    }

    public static func dismissKeyboardAfterSend(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.dismissKeyboardAfterSend) as? Bool ?? defaultDismissKeyboardAfterSend
    }

    /// Whether a message sent while the agent is still working steers it
    /// (acpmux `_meta.acpmux.steer`) rather than queueing after the turn.
    public static func steersFollowUps(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: Key.followUp) == steerFollowUp
    }
}
