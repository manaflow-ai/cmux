/// `diagnostics.hangReports` in cmux-next.json: whether this Mac sends opt-in hang reports
/// (plans/cmux-next/hang-reports-DESIGN.md). Off by default; only NIGHTLY builds send. Agents
/// may not change it (`AgentRefusal.privacy`).
///
/// Read from the snapshot's document, not stored: a value that is not `true` is off.
public nonisolated struct HangReportsSetting: Sendable {
    // `configPath` and `fallback` (off: nothing is sent until the person turns it on) are
    // generated from schemas/settings/source/hang-reports.json.

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: `true` only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }
}
