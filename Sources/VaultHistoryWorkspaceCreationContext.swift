import Foundation

/// Semantic origin of a workspace insertion for History recording.
enum VaultHistoryWorkspaceCreationContext: Equatable, Sendable {
    /// A user, command, or integration intentionally created a workspace.
    case semanticCreation
    /// A placeholder workspace was inserted while constructing a manager.
    case bootstrap
    /// A previously persisted workspace was reconstructed from a snapshot.
    case restoration
    /// A placeholder preserved the invariant that every live window has a workspace.
    case structuralReplacement

    var recordsCreationEvent: Bool {
        self == .semanticCreation
    }
}
