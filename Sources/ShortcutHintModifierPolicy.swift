import AppKit

enum ShortcutHintModifierPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30

    static func shouldShowHints(
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

    static func shouldShowControlHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.control] else { return false }
        return ShortcutHintDebugSettings.showHintsOnControlHoldEnabled(defaults: defaults)
    }

    static func shouldShowCommandHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == [.command] else { return false }
        return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
    }

    static func isCurrentWindow(
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

    static func shouldShowHints(
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
