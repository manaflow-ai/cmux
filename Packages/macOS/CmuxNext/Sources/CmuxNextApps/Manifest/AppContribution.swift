/// One entry of `contributes.<kind>`. The common fields are typed; the
/// whole entry stays in `raw` so newer keys survive (spec section 3).
public nonisolated struct AppContribution: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case sidebarSection = "sidebarSections"
        case command = "commands"
        case statusItem = "statusItems"
        case sidebar = "sidebars"
        case paneKind = "paneKinds"
        case theme = "themes"
        case skill = "skills"
        case agent = "agents"
        case mcpServer = "mcpServers"
        case automation = "automations"
    }

    public var kind: Kind
    /// Unique within the app (`prs`).
    public var id: String
    public var title: AppLocalizedText?
    public var symbol: String?
    /// The `main` export that renders it (`render`) or runs it (`run`).
    public var export: String?
    public var raw: [String: AppJSON]

    init(kind: Kind, raw: [String: AppJSON]) {
        self.kind = kind
        self.raw = raw
        id = raw["id"]?.stringValue ?? ""
        title = AppLocalizedText(json: raw["title"])
        symbol = raw["symbol"]?.stringValue
        export = (raw["render"] ?? raw["run"])?.stringValue
    }

    /// `defaultRegion` of a sidebar section (`middle` when absent).
    public var defaultRegion: String { raw["defaultRegion"]?.stringValue ?? "middle" }
    /// `maxRows` of a sidebar section.
    public var maxRows: Int? { raw["maxRows"]?.numberValue.map { Int($0) } }
    /// `placement` of a status item (`titlebar` when absent).
    public var placement: String { raw["placement"]?.stringValue ?? "titlebar" }
}

/// `contributes` of a manifest, by kind.
public nonisolated struct AppContributions: Sendable, Hashable {
    public var entries: [AppContribution]
    /// `contributes.settings` (a JSON Schema object), when declared.
    public var settingsSchema: [String: AppJSON]?

    public init(entries: [AppContribution] = [], settingsSchema: [String: AppJSON]? = nil) {
        self.entries = entries
        self.settingsSchema = settingsSchema
    }

    init(json: AppJSON?) {
        let object = json?.objectValue ?? [:]
        entries = AppContribution.Kind.allCases.flatMap { kind in
            (object[kind.rawValue]?.arrayValue ?? []).compactMap(\.objectValue).map { AppContribution(kind: kind, raw: $0) }
        }
        settingsSchema = object["settings"]?.objectValue
    }

    public func of(_ kind: AppContribution.Kind) -> [AppContribution] { entries.filter { $0.kind == kind } }

    /// Default setting values from `settings.properties.<key>.default`.
    public var settingsDefaults: [String: AppJSON] {
        (settingsSchema?["properties"]?.objectValue ?? [:]).compactMapValues { $0["default"] }
    }
}
