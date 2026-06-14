public import AppKit

/// Which modifier(s) activate keyboard shortcut hints. Pure value forwarding to
/// `ShortcutHintModifierPolicy` for the actual gate.
public enum ShortcutHintModifierActivation {
    case commandOrControl
    case commandOnly
    case controlOnly

    /// Whether hints should show for the held modifier flags under this
    /// activation mode.
    public func shouldShowHints(
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
