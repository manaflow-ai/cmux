/// `appearance.agentSignature`: each agent's dot glyph, made by acpmux from its session id
/// (`session/signature`), on sidebar agent rows and the chat's running line. Off unless set to
/// true: it changes the default look, so it is a customization (Leo: "some of them maybe just as
/// customizations lol if it affects default looks"). Off, nothing draws and nothing is asked.
public struct AgentSignatureSetting: Sendable {
    /// Creates the setting parser.
    public init() {}

    /// Parses a bool, treating an absent value as the default (off).
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: Self.configPath) else { return Self.fallback }
        guard let enabled = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.agentSignature",
                                                  message: "expected true or false"))
            return Self.fallback
        }
        return enabled
    }
}
