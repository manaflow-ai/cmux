/// `diagnostics.usageSharing` in cmux-next.json: whether this Mac also sends its usage record
/// (``UsageRecordingSetting``) to the person's cmux team, with `cmux usage upload`. It has effect
/// only while usage recording is on. Off by default; agents may not change it
/// (`AgentRefusal.privacy`), and the app shares only with this Mac's own consent record.
///
/// Read from the snapshot's document, not stored: a value that is not `true` is off.
public nonisolated struct UsageSharingSetting: Sendable {
    /// The cmux-next.json key path.
    public static let path = ["diagnostics", "usageSharing"]
    /// Off: nothing is shared until the person turns it on.
    public static let defaultValue = false

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: `true` only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }
}
