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

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        Self()
    }
}
