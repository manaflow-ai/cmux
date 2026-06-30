import AppKit

extension GhosttyNSView {
    func modifierFlagsForOpenURLAction() -> NSEvent.ModifierFlags {
        if let activeMouseOpenURLModifierFlags {
            return activeMouseOpenURLModifierFlags
        }
        if let recentMouseOpenURLModifierFlags,
           ProcessInfo.processInfo.systemUptime <= recentMouseOpenURLModifierFlagsDeadline {
            return recentMouseOpenURLModifierFlags
        }
        return NSEvent.modifierFlags
    }

    func withMouseOpenURLModifierFlags<T>(
        _ flags: NSEvent.ModifierFlags,
        _ work: () -> T
    ) -> T {
        let previous = activeMouseOpenURLModifierFlags
        recentMouseOpenURLModifierFlags = flags
        recentMouseOpenURLModifierFlagsDeadline = ProcessInfo.processInfo.systemUptime + 2
        activeMouseOpenURLModifierFlags = flags
        defer { activeMouseOpenURLModifierFlags = previous }
        return work()
    }
}
