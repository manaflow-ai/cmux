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

    @Test func debounceCoalescesWorkspaceIDsAcrossCancelledSchedules() {
        let pending = WorkspaceChangesSummaryRefreshScope.groupOnlyDelta
            .coalesced(with: .workspaceDelta(["workspace-a", "workspace-b"]))
            .coalesced(with: .workspaceDelta(["workspace-b", "workspace-c"]))

        #expect(
            pending.workspaceIDs(fullSnapshotWorkspaceIDs: ["workspace-z"])
                == ["workspace-a", "workspace-b", "workspace-c"]
        )
    }

    @Test func allWorkspacesRequestDominatesNarrowerDebounceScopes() {
        let pending = WorkspaceChangesSummaryRefreshScope
            .workspaceDelta(["workspace-a"])
            .coalesced(with: .fullSnapshot)
            .coalesced(with: .workspaceDelta(["workspace-b"]))

        #expect(
            pending.workspaceIDs(fullSnapshotWorkspaceIDs: ["workspace-a", "workspace-b"])
                == ["workspace-a", "workspace-b"]
        )
    }
}
