public import Foundation

/// A browser profile candidate included in an ambiguous `pane.create` error.
public struct ControlPaneBrowserProfileCandidate: Sendable, Equatable {
    /// The candidate's stable profile identifier.
    public let id: UUID
    /// The candidate's human-readable display name.
    public let displayName: String

    /// Creates an ambiguous browser profile candidate.
    /// - Parameters:
    ///   - id: The candidate's stable profile identifier.
    ///   - displayName: The candidate's human-readable display name.
    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
