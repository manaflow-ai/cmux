// The paths, defaults and ranges are generated from schemas/settings/source/subsessions.json
// (Schema/SettingsSchema+Subsessions.generated.swift); this file only parses.

/// `agents.subsessions.*` in cmux.json: whether agent sessions may start their own
/// sub-sessions, whether a session answers its sub-sessions' questions, how many each may have
/// open and run at once, and how deep they nest. The acpmux daemon reads the same file and enforces them; the
/// app shows and validates them.
public nonisolated struct SubsessionSettings: Sendable, Equatable {
    public var enabled = SubsessionSettings.subsessionsEnabledDefault
    public var answerQuestions = SubsessionSettings.subsessionsAnswerQuestionsDefault
    public var maxChildren = SubsessionSettings.subsessionsMaxChildrenDefault
    public var maxRunning = SubsessionSettings.subsessionsMaxRunningDefault
    public var maxDepth = SubsessionSettings.subsessionsMaxDepthDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["agents", "subsessions"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.bool("answerQuestions") { settings.answerQuestions = value }
        if let value = reader.number("maxChildren", range: subsessionsMaxChildrenRange) { settings.maxChildren = value }
        if let value = reader.number("maxRunning", range: subsessionsMaxRunningRange) { settings.maxRunning = value }
        if let value = reader.number("maxDepth", range: subsessionsMaxDepthRange) { settings.maxDepth = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
