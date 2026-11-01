public import AppKit

/// The classic intentional-hold rule, without a timer or window dependency.
public struct ShortcutHintModifierPolicy {
    public init() {}
    public static let intentionalHoldDelay: Duration = .milliseconds(300)
    private var suppressed = false
    private var held = false
    /// A key while held suppresses the hints until release, unless it `keepsHints` (a pane-navigation key).
    public mutating func keyDown(keepsHints: Bool = false) {
        if !keepsHints { suppressed = held }
    }

    /// The held set a hold may show hints for: Cmd, Ctrl or Option, alone or together, with or without Shift.
    public static func armed(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        let modifiers = flags.intersection([.command, .control, .shift, .option])
        return modifiers.isDisjoint(with: [.command, .control, .option]) ? nil : modifiers
    }

    public mutating func update(flags: NSEvent.ModifierFlags, eligible: Bool, elapsed: Duration) -> Bool {
        held = !flags.isDisjoint(with: [.command, .control, .shift, .option])
        if !held { suppressed = false }
        return eligible && !suppressed && Self.armed(flags) != nil && elapsed >= Self.intentionalHoldDelay
    }
}
