// The path and default are generated from schemas/settings/source/models.json
// (Schema/SettingsSchema+Models.generated.swift); this file only reads.

/// `models.*` in cmux.json (Settings > Models, cmux-tui/docs/model-connections.md). The connections
/// themselves live in acpmux; `spreadUsage` is the one switch the schema owns, so the palette,
/// `cmux settings` and MCP reach it. The app mirrors it into acpmux (`_acpmux/connections/spread.set`).
public nonisolated struct ModelsSettings: Sendable, Equatable {
    public var spreadUsage = ModelsSettings.spreadUsageDefault

    public init() {}

    /// The values in a settings root; a missing or mistyped key keeps its default.
    public init(root: JSONValue) {
        if case .bool(let on)? = root.value(at: Self.spreadUsagePath) { spreadUsage = on }
    }
}
