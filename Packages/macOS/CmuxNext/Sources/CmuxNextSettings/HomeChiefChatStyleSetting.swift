/// `home.chiefChatIMessageStyle` in cmux.json: the Chief chat's bubbles look like iMessage's (Messages'
/// blue for the person, its grey for the Chief). Off by default: the bubbles take the active theme's
/// colours, the person's the theme's accent and the Chief's the theme's surface (Leo 2026-10-19:
/// Messages' blue looks out of place over cmux's tinted glass themes). Looks only, so agents may set it.
public nonisolated struct HomeChiefChatStyleSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "chiefChatIMessageStyle"]
    public static let key = configPath.joined(separator: ".")
}

extension CmuxConfigSnapshot {
    /// `home.chiefChatIMessageStyle`: absent is off; a value that is not a bool is off plus a diagnostic.
    mutating func takeHomeChatStyle(_ root: JSONValue) {
        take(Self.parseLabsToggle(root, path: HomeChiefChatStyleSetting.configPath, fallback: false), \.homeChiefChatIMessageStyle)
    }
}
