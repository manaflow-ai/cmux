/// Parsed `c=<category>;p=<0|1>` meta segment from a v1 notification payload.
///
/// Returns `nil` unless BOTH a known category literal and a valid `p=0|1`
/// pending flag are present, so the reserved suffix grammar is exactly the
/// three known categories; any other `c=...` tail stays part of the legacy
/// notification body. (`.other` never rides the wire: senders omit the meta
/// entirely for ungated alerts.)
public struct AgentNotificationMeta: Sendable, Equatable {
    /// The parsed agent notification category.
    public let category: AgentNotifyCategory
    /// Whether background work or a scheduled wakeup is still pending.
    public let pending: Bool

    /// Creates metadata from the exact `c=<category>;p=<0|1>` wire segment.
    ///
    /// - Parameter meta: The trimmed candidate metadata segment.
    public init?(meta: String) {
        // Accept ONLY the exact canonical serialization the CLI emits
        // (`c=<known-category>;p=<0|1>`, two fields, this order, no extras).
        // Anything else -- reordered, duplicated, or trailing fields -- is not
        // metadata and stays part of the legacy body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2,
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))),
              known != .other else { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        self.category = known
    }
}
