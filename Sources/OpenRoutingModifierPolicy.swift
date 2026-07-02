import AppKit

struct OpenRoutingModifierPolicy {
    nonisolated func shouldBypassCmuxOpenRouting(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.shift) else { return false }
        return flags.isDisjoint(with: [.control, .option])
    }
}
