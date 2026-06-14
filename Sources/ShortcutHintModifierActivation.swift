import AppKit

enum ShortcutHintModifierActivation {
    case commandOrControl
    case commandOnly
    case controlOnly

    func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch self {
        case .commandOrControl:
            return ShortcutHintModifierPolicy.shouldShowHints(for: modifierFlags, defaults: defaults)
        case .commandOnly:
            return ShortcutHintModifierPolicy.shouldShowCommandHints(for: modifierFlags, defaults: defaults)
        case .controlOnly:
            return ShortcutHintModifierPolicy.shouldShowControlHints(for: modifierFlags, defaults: defaults)
        }
    }
}
