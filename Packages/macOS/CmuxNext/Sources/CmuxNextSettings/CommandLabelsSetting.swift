/// `agentPane.display.commandLabels` in cmux-next.json: how the agent chat names background
/// commands that its built-in rules do not know (webviews session-info/commandLabelSettings.ts).
/// Each item is a preset's name, or a rule of the person's own:
///
/// ```json
/// "commandLabels": [
///   "cmux-fleet",
///   { "program": "deploy", "match": "^deploy (\\S+)", "label": "Deploying {1}",
///     "link": "https://deploys.example.com/{1}", "icon": "cloud" }
/// ]
/// ```
///
/// A rule needs a non-blank `label` and a `program` (a name or a list of names) or a `match`
/// pattern, or both; `link` and `icon` are optional strings. The page compiles the pattern and
/// skips one that does not compile, and skips a preset name it does not know.
public nonisolated struct CommandLabelsSetting: Sendable {
    /// The key's path.
    public let configPath = AgentPaneDisplaySettingsSchema.section + ["commandLabels"]

    public init() {}

    /// Whether `value` is a list of preset names and rules (the Settings write check; the same
    /// rule as cmux-config `is_command_label` and webviews validate.ts `isCommandLabel`).
    public static func accepts(_ value: JSONValue) -> Bool {
        guard case .array(let items) = value else { return false }
        return items.allSatisfy(isItem)
    }

    private static func nonBlank(_ value: JSONValue) -> Bool {
        value.stringValue.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    private static func isItem(_ value: JSONValue) -> Bool {
        if value.stringValue != nil { return nonBlank(value) }
        guard case .object(let members) = value, members["label"].map(nonBlank) ?? false else { return false }
        if let program = members["program"] {
            let names = program.arrayValue ?? [program]
            guard !names.isEmpty, names.allSatisfy(nonBlank) else { return false }
        }
        if let match = members["match"], !nonBlank(match) { return false }
        for key in ["link", "icon"] {
            if let member = members[key], member.stringValue == nil { return false }
        }
        return members["program"] != nil || members["match"] != nil
    }

    /// Values the schema export lists as accepted and refused (SettingsSchemaSamples).
    static let acceptedSamples: [JSONValue] = [
        .array([]),
        .array([.string("cmux-fleet")]),
        .array([.object(["program": .string("deploy"), "label": .string("Deploying")]),
                .object(["match": .string("^make (\\w+)"), "label": .string("Making {1}"), "icon": .string("mode.build"),
                         "link": .string("https://example.com/{1}")]),
                .object(["program": .array([.string("a"), .string("b")]), "label": .string("A or B")])]),
    ]
    static let refusedSamples: [JSONValue] = [
        .string("cmux-fleet"),
        .array([.string(" ")]),
        .array([.object(["label": .string("No program or pattern")])]),
        .array([.object(["program": .string("x")])]),
        .array([.object(["program": .array([]), "label": .string("x")])]),
        .array([.object(["program": .string("x"), "label": .string("x"), "icon": .number(1)])]),
        .array([.number(1)]),
    ]
}
