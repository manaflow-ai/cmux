public import AppKit

/// Decides whether keyboard shortcut-hint overlays should be shown for a given
/// set of held modifier flags and the host/event window identity. No mutable
/// state; reads feature flags from ``ShortcutHintDebugSettings``.
public struct ShortcutHintModifierPolicy {
    /// Hold duration before an intentional modifier-hold is treated as a
    /// request to show hints.
    public static let intentionalHoldDelay: TimeInterval = 0.30

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether hints should show for the held modifiers (command or control).
    public func shouldShowHints(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch normalized {
        case [.command]:
            return ShortcutHintDebugSettings(defaults: defaults).showHintsOnCommandHoldEnabled
        case [.control]:
            return ShortcutHintDebugSettings(defaults: defaults).showHintsOnControlHoldEnabled
        default:
            return false
        }
    }

    /// Whether control-hold hints should show for exactly the control modifier.
    public func shouldShowControlHints(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.control] else { return false }
        return ShortcutHintDebugSettings(defaults: defaults).showHintsOnControlHoldEnabled
    }

    /// Whether command-hold hints should show for exactly the command modifier.
    public func shouldShowCommandHints(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.command] else { return false }
        return ShortcutHintDebugSettings(defaults: defaults).showHintsOnCommandHoldEnabled
    }

    /// Whether the event/key window matches the host window so hints are scoped
    /// to the active window only.
    public func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    /// Combined gate: hints show only when both the modifier policy and the
    /// current-window check pass.
    public func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        shouldShowHints(for: modifierFlags) &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}
