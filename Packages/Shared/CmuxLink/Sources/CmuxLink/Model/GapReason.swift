/// Why a channel skipped revisions.
public enum GapReason: UInt8, Sendable, Hashable {
    /// The sender no longer retained the messages after the cursor.
    case retentionExceeded = 1
    /// The peer started a new session epoch (host restart, expired session).
    case newEpoch = 2
}
