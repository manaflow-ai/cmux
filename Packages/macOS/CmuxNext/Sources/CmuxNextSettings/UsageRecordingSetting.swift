/// `diagnostics.usageRecording` in cmux-next.json: whether this Mac records how cmux is used
/// (which surfaces hold the keyboard, which actions run and how, how much is open) into local
/// files a report reads (cmux-tui/crates/cmux-usage). Shape only, never content: no titles,
/// paths, addresses or text. Off by default; nothing leaves the Mac. Agents may not change it
/// (`AgentRefusal.privacy`).
///
/// Read from the snapshot's document, not stored: a value that is not `true` is off.
public nonisolated struct UsageRecordingSetting: Sendable {
    /// The cmux-next.json key path.
    public static let path = ["diagnostics", "usageRecording"]
    /// Off: nothing is recorded until the person turns it on.
    public static let defaultValue = false

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: `true` only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }
}
