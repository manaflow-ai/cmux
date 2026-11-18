public import CmuxNextDesign

nonisolated extension AttentionSettings {
    /// Whether reading a pane by `trigger` flashes its ring as it goes: going into it (focusing
    /// it, a click, a key, an open), as in classic, where focusing a pane with an unread
    /// notification played its dismiss flash (https://github.com/manaflow-ai/cmux/issues/42210),
    /// unless `notifications.attention.flash` is off, or the key under `flashOnTyping` off.
    public func flashesOnEntry(_ trigger: NotificationTrigger) -> Bool {
        guard flashesOnRead, [.focus, .click, .keystroke, .open].contains(trigger) else { return false }
        return trigger != .keystroke || flashesOnTyping
    }
}
