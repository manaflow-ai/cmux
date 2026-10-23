/// `diagnostics.hangReports` in cmux-next.json: whether this Mac sends opt-in hang reports
/// (plans/cmux-next/hang-reports-DESIGN.md). Off by default; only NIGHTLY builds send. Agents
/// may not change it (`AgentRefusal.privacy`).
///
/// Read from the snapshot's document, not stored: a value that is not `true` is off.
public nonisolated struct HangReportsSetting: Sendable {
    public static let path = ["diagnostics", "hangReports"]
    public static let defaultValue = false

    public init() {}

    /// The value in `root`: `true` only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }
}

extension CmuxConfigSnapshot {
    /// `diagnostics.hangReports` (``HangReportsSetting``).
    public var hangReports: Bool { HangReportsSetting().value(in: root) }
}
