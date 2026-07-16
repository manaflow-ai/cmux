/// Controls how many pull-request refresh chains may run concurrently.
public protocol PullRequestPanelRefreshLimiting: Sendable {
    /// Waits for a refresh permit, returning `false` if cancellation wins first.
    func acquirePullRequestRefresh() async -> Bool

    /// Returns a previously acquired refresh permit.
    func releasePullRequestRefresh() async
}
