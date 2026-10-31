/// `agentPane.needsYou.enabled` in cmux.json: whether the agent chat's header shows Needs you, the
/// badge that counts every open ask and lists them with their answers (webviews
/// needsYou/NeedsYou.tsx). An App Store item, off by default (Leo 2026-10-22: "app store maybe?").
/// The App gives it to new agent pages (`AgentPaneTunables.needsYouInstalled`); off, a page gets
/// `needs-you="off"` whatever Debug Settings' `agentPane.debug.needsYou` says.
public nonisolated struct AgentPaneNeedsYouSetting {
    public nonisolated init() {}
    public static let enabledPath = ["agentPane", "needsYou", "enabled"]
    /// Off until the person gets it from the App Store or Settings.
    public static let fallback = false
}

nonisolated extension CmuxConfigSnapshot {
    /// `agentPane.needsYou.enabled`; a value that is not a bool reads as the default (the schema
    /// row's validation reports it).
    public var agentPaneNeedsYouEnabled: Bool {
        root.value(at: AgentPaneNeedsYouSetting.enabledPath)?.boolValue ?? AgentPaneNeedsYouSetting.fallback
    }
}
