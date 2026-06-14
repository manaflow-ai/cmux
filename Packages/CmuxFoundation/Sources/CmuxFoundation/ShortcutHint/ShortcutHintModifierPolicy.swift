public import AppKit

/// Pure policy deciding whether keyboard shortcut-hint overlays should be shown
/// for a given set of held modifier flags and the host/event window identity.
/// No mutable state; reads feature flags from `ShortcutHintDebugSettings`.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum ShortcutHintModifierPolicy {
    /// Hold duration before an intentional modifier-hold is treated as a
    /// request to show hints.
    public static let intentionalHoldDelay: TimeInterval = 0.30

    /// Whether hints should show for the held modifiers (command or control).
    public static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch normalized {
        case [.command]:
            return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
        case [.control]:
            return ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults)
        default:
            return false
        }
    }

    /// Whether control-hold hints should show for exactly the control modifier.
    public static func shouldShowControlHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.control] else { return false }
        return ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults)
    }

    /// Whether command-hold hints should show for exactly the command modifier.
    public static func shouldShowCommandHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.command] else { return false }
        return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
    }

    /// Whether the event/key window matches the host window so hints are scoped
    /// to the active window only.
    public static func isCurrentWindow(
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
    public static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldShowHints(for: modifierFlags, defaults: defaults) &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}
