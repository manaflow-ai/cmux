import Dispatch
import Foundation

/// Shared bounded inputs for one recursive Git metadata watch plan.
nonisolated struct GitMetadataWatchInputs: Sendable {
    /// Aggregate deadline shared by the planner and final descriptor build.
    let deadline: DispatchTime
    let configPathsByRepository: [String: [String]]
    /// Existing parent roots watched only for creation of missing config files.
    let watchOnlyPathsByRepository: [String: [String]]
    /// Missing optional include files watched through exact path sentinels.
    let metadataSentinelPathsByRepository: [String: [String]]
    let indexSnapshotsByRepository: [String: GitIndexSnapshot]
    /// Repositories whose index format requires a conservative work-tree root.
    let forceWorkTreeRootRepositories: Set<String>
}
