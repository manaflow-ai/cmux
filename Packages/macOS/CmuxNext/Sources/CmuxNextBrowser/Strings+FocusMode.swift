import Foundation

// Browser focus mode's omnibar badge (classic cmux parity).
extension Strings {
    static var focusModeActive: String {
        String(localized: "browser.focusMode.active", defaultValue: "Focus Mode", bundle: .module)
    }
    static var focusModeArmed: String {
        String(localized: "browser.focusMode.armed", defaultValue: "Esc again to exit", bundle: .module)
    }
    /// The badge's tooltip: how to leave (`%@` is the double-Escape hint).
    static func focusModeExitHelp(_ hint: String) -> String {
        String(format: String(localized: "browser.focusMode.exit.help", defaultValue: "Exit browser focus mode (%@)", bundle: .module), hint)
    }
    static var focusModeEscapeHint: String {
        String(localized: "browser.focusMode.shortcutHint", defaultValue: "Esc Esc", bundle: .module)
    }
}
