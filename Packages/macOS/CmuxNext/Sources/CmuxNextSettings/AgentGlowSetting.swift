/// `appearance.agentGlow` in cmux.json: off by default, so the window background looks the way
/// `appearance.*` asks for and nothing reacts to agents. On, the window background stays calm while
/// agents are idle and takes a soft glow in the machine's color when an agent needs you. It only
/// adds the glow and never changes the `appearance.*` values, so turning it off restores the
/// usual look.
public nonisolated struct AgentGlowSetting {
    public nonisolated init() {}

    /// A missing key is off with no diagnostic; a bad value is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.agentGlow",
                                                 message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
