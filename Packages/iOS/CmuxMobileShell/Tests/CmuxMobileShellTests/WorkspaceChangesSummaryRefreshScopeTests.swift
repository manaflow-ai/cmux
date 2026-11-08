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

    @Test func routineLegacyListReloadKeepsTheSummaryRequestTTLRespecting() throws {
        var policy = WorkspaceChangesSummaryRefreshSchedulePolicy()

        let startsDebounce = policy.schedule(scope: .fullSnapshot, force: false)
        let pendingRequest = policy.beginFetchAfterDebounce()
        let request = try #require(pendingRequest)

        #expect(startsDebounce)
        #expect(request.scope == .fullSnapshot)
        #expect(!request.force)
    }

    @Test func explicitUserRefreshStillForcesTheSummaryRequest() throws {
        var policy = WorkspaceChangesSummaryRefreshSchedulePolicy()

        let startsDebounce = policy.schedule(scope: .fullSnapshot, force: false)
        let restartsDebounce = policy.schedule(
            scope: .workspaceDelta(["workspace-a"]),
            force: true
        )
        let pendingRequest = policy.beginFetchAfterDebounce()
        let request = try #require(pendingRequest)

        #expect(startsDebounce)
        #expect(restartsDebounce)
        #expect(request.scope == .fullSnapshot)
        #expect(request.force)
    }

    @Test func midFlightDeltasDoNotRestartDebounceAndDrainInOneTrailingPass() throws {
        var policy = WorkspaceChangesSummaryRefreshSchedulePolicy()
        let startsDebounce = policy.schedule(
            scope: .workspaceDelta(["workspace-a"]),
            force: false
        )
        let firstRequest = policy.beginFetchAfterDebounce()
        let firstPass = try #require(firstRequest)

        #expect(startsDebounce)
        #expect(
            firstPass.scope.workspaceIDs(fullSnapshotWorkspaceIDs: [])
                == ["workspace-a"]
        )
        #expect(policy.isFetchInFlight)
        let restartsForFirstDelta = policy.schedule(
            scope: .workspaceDelta(["workspace-b"]),
            force: false
        )
        let restartsForSecondDelta = policy.schedule(
            scope: .workspaceDelta(["workspace-c"]),
            force: true
        )
        #expect(!restartsForFirstDelta)
        #expect(!restartsForSecondDelta)
        #expect(!policy.isDebouncePending)
        #expect(policy.isFetchInFlight)

        let trailingRequest = policy.fetchCompleted()
        let trailingPass = try #require(trailingRequest)
        #expect(
            trailingPass.scope.workspaceIDs(fullSnapshotWorkspaceIDs: [])
                == ["workspace-b", "workspace-c"]
        )
        #expect(trailingPass.force)
        let additionalPass = policy.fetchCompleted()
        #expect(additionalPass == nil)
        #expect(!policy.isFetchInFlight)
    }

    @Test func deletedWorkspaceIsRemovedFromPendingRefreshScope() throws {
        var policy = WorkspaceChangesSummaryRefreshSchedulePolicy()
        _ = policy.schedule(
            scope: .workspaceDelta(["workspace-removed", "workspace-kept"]),
            force: false
        )

        policy.retainWorkspaces(in: WorkspaceChangesSummaryWorkspaceSet(
            workspaceIDs: ["workspace-kept"]
        ))
        let pendingRequest = policy.beginFetchAfterDebounce()
        let request = try #require(pendingRequest)

        #expect(
            request.scope.workspaceIDs(fullSnapshotWorkspaceIDs: [])
                == ["workspace-kept"]
        )
    }
}
