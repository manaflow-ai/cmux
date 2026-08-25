import Foundation

/// Shared bounded inputs for one recursive Git metadata watch plan.
nonisolated struct GitMetadataWatchInputs: Sendable {
    let configPathsByRepository: [String: [String]]
    let indexSnapshotsByRepository: [String: GitIndexSnapshot]
    /// Repositories whose index format requires a conservative work-tree root.
    let forceWorkTreeRootRepositories: Set<String>
}
