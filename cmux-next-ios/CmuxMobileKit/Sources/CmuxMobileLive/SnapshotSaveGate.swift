import CmuxMobileModel
import Foundation

/// Skips ``LiveCoordinator``'s snapshot build when nothing it reads changed since the last one.
/// The build filters every workspace per Mac and compares every row (O(workspaces) on the main
/// actor), and it ran on every one-row workspace event. With the same key and every live Mac's
/// stamp still under the stamp interval, the build returns the snapshot it holds, so skipping is
/// exact (`SnapshotSaveGateTests` checks it against the build on random event sequences).
struct SnapshotSaveGate {
    struct Key: Equatable {
        var team: Team
        /// `AppStore.workspacesRevision`: moves on every change of the workspaces.
        var workspacesRevision: Int
        var pending: Set<String>
        var liveMacIDs: [String]
        var linkedMacID: String?
        /// Moves whenever the coordinator's snapshot is set.
        var snapshotGeneration: Int
    }

    private var last: Key?

    /// Whether the build would return `snapshot` unchanged: the same inputs, and no live Mac's stamp due.
    func unchanged(_ key: Key, snapshot: LiveSnapshot?, now: Date, stampInterval: TimeInterval) -> Bool {
        guard let last, last == key, let snapshot else { return false }
        return key.liveMacIDs.allSatisfy { id in
            snapshot.workspaces[id].map { now.timeIntervalSince($0.savedAt) < stampInterval } ?? false
        }
    }

    /// Records the inputs of the build just done; `generation` is the snapshot's after it.
    mutating func saved(_ key: Key, generation: Int) {
        var key = key
        key.snapshotGeneration = generation
        last = key
    }
}
