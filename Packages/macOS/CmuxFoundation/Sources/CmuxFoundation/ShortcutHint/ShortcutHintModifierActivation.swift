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
        let policy = ShortcutHintModifierPolicy(defaults: defaults)
        switch self {
        case .commandOrControl:
            return policy.shouldShowHints(for: modifierFlags)
        case .commandOnly:
            return policy.shouldShowCommandHints(for: modifierFlags)
        case .controlOnly:
            return policy.shouldShowControlHints(for: modifierFlags)
        }
    }
}
