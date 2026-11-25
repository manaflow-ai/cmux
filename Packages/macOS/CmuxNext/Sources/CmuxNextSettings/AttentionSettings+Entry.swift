public import CmuxNextDesign

nonisolated extension AttentionSettings {
    /// Whether reading a pane by `trigger` flashes its ring as it goes: going into it (a click, a
    /// key, an open), as in classic, unless `notifications.attention.flash` is off, or the key
    /// under `flashOnTyping` off.
    public func flashesOnEntry(_ trigger: NotificationTrigger) -> Bool {
        guard flashesOnRead, [.click, .keystroke, .open].contains(trigger) else { return false }
        return trigger != .keystroke || flashesOnTyping
    }
}
