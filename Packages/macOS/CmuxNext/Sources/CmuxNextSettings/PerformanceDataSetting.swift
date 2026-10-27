/// `diagnostics.performanceData` in cmux-next.json: whether this Mac sends aggregate performance data, the
/// catalog histograms and stability counts only (plans/cmux-next/chrome-parity/p09-observability.md, task 134).
/// Off by default in every channel; agents may not change it (`AgentRefusal.privacy`).
///
/// Read from the snapshot's document, not stored: a value that is not `true` is off.
public nonisolated struct PerformanceDataSetting: Sendable {
    /// The cmux-next.json key path.
    public static let path = ["diagnostics", "performanceData"]
    /// Off: nothing is sent until the person turns it on.
    public static let defaultValue = false

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: `true` only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }

    /// What Settings and the palette offer of this row now: nothing while `featureEnabled` is false, that is while
    /// this build would send nothing (the app passes `HangReportsController.offersAggregates`: the
    /// `performanceDataReports` feature and the schema-3 wire format).
    public func availability(featureEnabled: Bool) -> SettingsAvailability {
        featureEnabled ? SettingsAvailability() : SettingsAvailability(hiddenRows: [Self.path.joined(separator: ".")])
    }
}

extension CmuxConfigSnapshot {
    /// `diagnostics.performanceData` (``PerformanceDataSetting``).
    public var performanceData: Bool { PerformanceDataSetting().value(in: root) }
}
