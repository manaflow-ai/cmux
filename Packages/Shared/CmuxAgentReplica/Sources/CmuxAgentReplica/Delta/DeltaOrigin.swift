import Foundation

/// Describes whether a mutation arrived live or during reconciliation.
public enum DeltaOrigin: String, Codable, Hashable, Sendable {
    /// A user-witnessed live mutation.
    case live
    /// A mutation replayed during resync.
    case resync
}
