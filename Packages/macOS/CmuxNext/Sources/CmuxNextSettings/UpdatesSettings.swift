/// How a ready update makes itself known (`updates.notify`).
public nonisolated enum UpdatesNotifySetting: String, Sendable, Hashable, CaseIterable {
    case card, badge, silent
}

/// `updates.*` in cmux.json (R114): automatic checks, downloads and
/// install on quit are on by default; every step can be turned off.
public nonisolated struct UpdatesSettings: Sendable, Equatable {
    public static let checkIntervalRange: ClosedRange<Double> = 900...604_800
    public var checkAutomatically = true
    /// Seconds between automatic checks.
    public var checkIntervalSeconds: Double = 3600
    public var downloadAutomatically = true
    public var installOnQuit = true
    public var notify: UpdatesNotifySetting = .card
    /// Hours in which a ready update shows no card; nil is off.
    public var quietHours: QuietHours?
    /// Previous builds kept for rollback (`cmux update rollback`).
    public var keepPreviousVersions = 1
    public static let keepPreviousVersionsRange: ClosedRange<Double> = 0...5

    public init() {}

    public static let checkAutomaticallyPath = ["updates", "checkAutomatically"]
    public static let checkIntervalPath = ["updates", "checkIntervalSeconds"]
    public static let downloadAutomaticallyPath = ["updates", "downloadAutomatically"]
    public static let installOnQuitPath = ["updates", "installOnQuit"]
    public static let notifyPath = ["updates", "notify"]
    public static let quietHoursPath = ["updates", "quietHours"]
    public static let keepPreviousVersionsPath = ["updates", "keepPreviousVersions"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["updates"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("checkAutomatically") { settings.checkAutomatically = value }
        if let value = reader.number("checkIntervalSeconds", range: checkIntervalRange) { settings.checkIntervalSeconds = value }
        if let value = reader.bool("downloadAutomatically") { settings.downloadAutomatically = value }
        if let value = reader.bool("installOnQuit") { settings.installOnQuit = value }
        if let value = reader.choice("notify", UpdatesNotifySetting.self) { settings.notify = value }
        if let value = reader.number("keepPreviousVersions", range: keepPreviousVersionsRange) { settings.keepPreviousVersions = Int(value) }
        diagnostics = reader.diagnostics
        settings.quietHours = quietHours(root, diagnostics: &diagnostics)
        return settings
    }

    private static func quietHours(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> QuietHours? {
        guard let value = root.value(at: quietHoursPath) else { return nil }
        if case .null = value { return nil }
        guard case .object(let members) = value,
              let start = members["start"]?.stringValue.flatMap(QuietHours.minutes),
              let end = members["end"]?.stringValue.flatMap(QuietHours.minutes) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "updates.quietHours",
                                                  message: "expected {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}"))
            return nil
        }
        return QuietHours(start: start, end: end)
    }
}
