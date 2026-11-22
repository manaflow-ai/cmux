/// The agent pane's edited-files card in cmux.json (the pane reads the same names,
/// webviews/src/agent-session/acpmux/turnChanges/settings.ts):
///
/// ```jsonc
/// "agentPane": { "editedFiles": { "show": "always", "maxRows": 5, "scope": "turn" } }
/// ```
///
/// `show`: always (default), collapsed (the header; a chevron shows the rows) or never (the plain
/// tool rows). `maxRows`: rows before "Show N more". `scope`: turn (a card per turn) or session (one
/// card, at the session's latest edit). A bad value is that key's default plus a diagnostic.
public nonisolated struct AgentPaneEditedFilesSetting: Sendable, Hashable {
    public static let showPath = ["agentPane", "editedFiles", "show"]
    public static let maxRowsPath = ["agentPane", "editedFiles", "maxRows"]
    public static let scopePath = ["agentPane", "editedFiles", "scope"]
    public static let shows = ["always", "collapsed", "never"]
    public static let scopes = ["turn", "session"]
    public static let maxRowsRange: ClosedRange<Double> = 1...50

    public var show = "always"
    public var maxRows = 5
    public var scope = "turn"

    public init() {}

    public static let fallback = AgentPaneEditedFilesSetting()

    /// The page's value (the `editedFiles` host event): `{show, maxRows, scope}`.
    public var pageValue: JSONValue { ["show": .string(show), "maxRows": JSONValue(maxRows), "scope": .string(scope)] }

    /// Each key is checked against its schema row, so the parser and the Settings window agree.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AgentPaneEditedFilesSetting {
        var setting = fallback
        for descriptor in AgentPaneEditedFilesSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path) else { continue }
            guard descriptor.accepts(value) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            switch descriptor.path {
            case showPath: setting.show = value.stringValue ?? setting.show
            case maxRowsPath: setting.maxRows = Int(value.doubleValue ?? 5)
            case scopePath: setting.scope = value.stringValue ?? setting.scope
            default: break
            }
        }
        return setting
    }
}
