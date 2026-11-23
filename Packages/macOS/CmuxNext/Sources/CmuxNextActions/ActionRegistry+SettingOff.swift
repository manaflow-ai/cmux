// Several owners turn actions off with `settingOffReason` (Import from Browser's setting, the
// window docks' Debug Setting, a build without hang reports): each adds its own reason, and the
// reasons added before stay.
extension ActionRegistry {
    /// Adds a reason to `settingOffReason`: while `reason` returns a string for an id, that action
    /// leaves the palette, menus and context menus, a keyboard run does nothing, and a CLI or MCP
    /// run is refused with the string.
    public func addSettingOffReason(_ reason: @escaping @MainActor (ActionID) -> String?) {
        let earlier = settingOffReason
        settingOffReason = { id in earlier(id) ?? reason(id) }
    }

    /// ``addSettingOffReason(_:)`` for a fixed set of ids that are off together while `reason`
    /// returns a string.
    public func addSettingOffReason(_ ids: Set<ActionID>, _ reason: @escaping @MainActor () -> String?) {
        addSettingOffReason { id in ids.contains(id) ? reason() : nil }
    }
}
