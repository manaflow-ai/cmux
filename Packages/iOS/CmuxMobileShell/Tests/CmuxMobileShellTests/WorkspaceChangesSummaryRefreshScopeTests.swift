import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesSummaryRefreshScopeTests {
    @Test func fullSnapshotsRefreshEveryProjectedWorkspace() {
        let ids = WorkspaceChangesSummaryRefreshScope.fullSnapshot.workspaceIDs(
            fullSnapshotWorkspaceIDs: ["workspace-a", "workspace-b"]
        )

        #expect(ids == ["workspace-a", "workspace-b"])
    }

    @Test func workspaceDeltasRefreshOnlyChangedRecords() {
        let ids = WorkspaceChangesSummaryRefreshScope
            .workspaceDelta(["workspace-b"])
            .workspaceIDs(fullSnapshotWorkspaceIDs: ["workspace-a", "workspace-b"])

        #expect(ids == ["workspace-b"])
    }

    @Test func groupOnlyDeltasDoNotRefreshWorkspaceSummaries() {
        let ids = WorkspaceChangesSummaryRefreshScope.groupOnlyDelta.workspaceIDs(
            fullSnapshotWorkspaceIDs: ["workspace-a", "workspace-b"]
        )

        #expect(ids.isEmpty)
    }
}
