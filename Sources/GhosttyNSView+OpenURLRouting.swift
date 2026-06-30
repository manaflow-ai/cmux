import AppKit

extension GhosttyNSView {
    func modifierFlagsForOpenURLAction() -> NSEvent.ModifierFlags {
        activeMouseOpenURLModifierFlags ?? NSEvent.modifierFlags
    }

    func withMouseOpenURLModifierFlags<T>(
        _ flags: NSEvent.ModifierFlags,
        _ work: () -> T
    ) -> T {
        let previous = activeMouseOpenURLModifierFlags
        activeMouseOpenURLModifierFlags = flags
        defer { activeMouseOpenURLModifierFlags = previous }
        return work()
    }
}
