import CmuxArtifacts
import Foundation

extension SessionWorkspaceSnapshot {
    @MainActor
    mutating func captureArtifactsState(from workspace: Workspace) {
        let records = workspace.artifactsState.artifactRecords
        artifacts = records.isEmpty ? nil : SessionWorkspaceArtifactsSnapshotCollection(records)
    }

    var restoredArtifacts: [ArtifactRecord] {
        artifacts?.records ?? []
    }
}
