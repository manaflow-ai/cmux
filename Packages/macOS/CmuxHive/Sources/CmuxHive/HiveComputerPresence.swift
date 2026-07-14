public import Foundation

/// Presence state for a ``HiveComputer`` row.
///
/// `online`/`offline` come from the live presence service once a snapshot has
/// arrived; before that (or when the service is unreachable) rows carry the
/// registry's durable last-seen hint as ``unknown(lastSeenAt:)``.
public enum HiveComputerPresence: Equatable, Sendable {
    /// The presence service reports at least one instance online.
    case online
    /// The presence service knows the computer and reports it offline.
    case offline(lastSeenAt: Date?)
    /// No live presence data; `lastSeenAt` is the registry/pairing hint.
    case unknown(lastSeenAt: Date?)

    /// Whether the computer is live right now.
    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    /// The best available last-seen timestamp, if any.
    public var lastSeenAt: Date? {
        switch self {
        case .online: return nil
        case .offline(let lastSeenAt), .unknown(let lastSeenAt): return lastSeenAt
        }
    }
}
