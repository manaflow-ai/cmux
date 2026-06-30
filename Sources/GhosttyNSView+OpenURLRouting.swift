import AppKit

extension GhosttyNSView {
    func modifierFlagsForOpenURLAction() -> NSEvent.ModifierFlags {
        if let activeMouseOpenURLModifierFlags {
            recentMouseOpenURLModifierFlags = nil
            recentMouseOpenURLModifierFlagsDeadline = 0
            return activeMouseOpenURLModifierFlags
        }
        defer {
            recentMouseOpenURLModifierFlags = nil
            recentMouseOpenURLModifierFlagsDeadline = 0
        }
        if let recentMouseOpenURLModifierFlags,
           ProcessInfo.processInfo.systemUptime <= recentMouseOpenURLModifierFlagsDeadline {
            return recentMouseOpenURLModifierFlags
        }
        return []
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

    func noteOpenURLRouteHandledForCurrentMouseEvent() {
        recentHandledOpenURLRouteDeadline = ProcessInfo.processInfo.systemUptime + 2
    }

    func shouldSuppressDefaultApplicationFallbackForHandledOpenURL(ghosttyConsumed: Bool) -> Bool {
        guard ghosttyConsumed,
              ProcessInfo.processInfo.systemUptime <= recentHandledOpenURLRouteDeadline else {
            return false
        }
        recentHandledOpenURLRouteDeadline = 0
        return true
    }
}
