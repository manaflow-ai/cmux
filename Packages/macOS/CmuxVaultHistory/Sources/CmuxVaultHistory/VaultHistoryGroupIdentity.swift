public import Foundation

/// Locale-independent identity of one grouped History section.
public enum VaultHistoryGroupIdentity: Hashable, Sendable {
    /// A rolling or calendar date bucket.
    case date(VaultHistoryDateBucket)
    /// A concrete workspace identity.
    case workspace(UUID)
    /// A concrete window identity.
    case window(UUID)
    /// A concrete locale-independent agent identity.
    case agent(String)
    /// A concrete event category.
    case kind(VaultHistoryEventKind)
    /// Events missing the identity required by the selected group key.
    case other

    /// Stable string identity used by grouped views and tests.
    public var id: String {
        switch self {
        case let .date(bucket):
            "date:\(bucket.rawValue)"
        case let .workspace(id):
            "workspace:\(id.uuidString)"
        case let .window(id):
            "window:\(id.uuidString)"
        case let .agent(id):
            "agent:\(id)"
        case let .kind(kind):
            "kind:\(kind.rawValue)"
        case .other:
            "other"
        }
    }
}
