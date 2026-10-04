import AppKit

/// The classic intentional-hold rule, without a timer or window dependency.
struct ShortcutHintModifierPolicy {
    static let intentionalHoldDelay: Duration = .milliseconds(300)
    private var suppressed = false

    mutating func keyDown() { suppressed = true }

    mutating func update(flags: NSEvent.ModifierFlags, eligible: Bool, elapsed: Duration) -> Bool {
        let modifiers = flags.intersection([.command, .control, .shift, .option])
        if modifiers.isEmpty { suppressed = false }
        return eligible && !suppressed && (modifiers == .command || modifiers == .control)
            && elapsed >= Self.intentionalHoldDelay
    }
}
