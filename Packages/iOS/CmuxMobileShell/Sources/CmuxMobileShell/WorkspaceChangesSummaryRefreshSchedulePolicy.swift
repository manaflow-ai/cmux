/// Owns debounce and single-flight transitions for workspace summary refreshes.
struct WorkspaceChangesSummaryRefreshSchedulePolicy: Sendable {
    private(set) var isDebouncePending = false
    private(set) var isFetchInFlight = false
    private var pendingScope = WorkspaceChangesSummaryRefreshScope.groupOnlyDelta
    private var pendingForce = false

    /// Accumulates a refresh and reports whether the debounce should restart.
    mutating func schedule(
        scope: WorkspaceChangesSummaryRefreshScope,
        force: Bool
    ) -> Bool {
        pendingScope = pendingScope.coalesced(with: scope)
        pendingForce = pendingForce || force
        guard pendingScope != .groupOnlyDelta, !isFetchInFlight else {
            return false
        }
        isDebouncePending = true
        return true
    }

    /// Drains the debounced scope into the first single-flight pass.
    mutating func beginFetchAfterDebounce() -> (
        scope: WorkspaceChangesSummaryRefreshScope,
        force: Bool
    )? {
        isDebouncePending = false
        guard !isFetchInFlight, pendingScope != .groupOnlyDelta else {
            return nil
        }
        isFetchInFlight = true
        return drainPendingRequest()
    }

    /// Completes one pass and drains one accumulated trailing pass, if needed.
    mutating func fetchCompleted() -> (
        scope: WorkspaceChangesSummaryRefreshScope,
        force: Bool
    )? {
        guard isFetchInFlight else { return nil }
        guard pendingScope != .groupOnlyDelta else {
            isFetchInFlight = false
            return nil
        }
        return drainPendingRequest()
    }

    /// Removes deleted workspaces from the pending refresh scope.
    mutating func retainWorkspaces(in workspaceSet: WorkspaceChangesSummaryWorkspaceSet) {
        pendingScope = workspaceSet.scope(retaining: pendingScope)
    }

    /// Clears all pending and in-flight bookkeeping at a connection boundary.
    mutating func reset() {
        isDebouncePending = false
        isFetchInFlight = false
        pendingScope = .groupOnlyDelta
        pendingForce = false
    }

    private mutating func drainPendingRequest() -> (
        scope: WorkspaceChangesSummaryRefreshScope,
        force: Bool
    ) {
        let request = (scope: pendingScope, force: pendingForce)
        pendingScope = .groupOnlyDelta
        pendingForce = false
        return request
    }
}
