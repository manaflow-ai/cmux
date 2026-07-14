public import CmuxFoundation

/// Resolves and mutates one workspace branch's GitHub pull request exclusively through `gh`.
public actor GitHubPullRequestPanelService: PullRequestPanelServing {
    static let cacheCapacity = 32

    nonisolated let commandRunner: any CommandRunning
    nonisolated let gitMetadataService: GitMetadataService
    var cacheByContext: [PullRequestPanelContext: PullRequestPanelContent] = [:]
    var cacheRecency: [PullRequestPanelContext] = []
    var latestRefreshSequenceByContext: [PullRequestPanelContext: UInt64] = [:]
    var refreshSequence: UInt64 = 0

    /// Creates a GitHub CLI pull-request service.
    /// - Parameters:
    ///   - commandRunner: The async subprocess runner; tests inject a fake.
    ///   - gitMetadataService: The repository and branch resolver.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        gitMetadataService: GitMetadataService = GitMetadataService()
    ) {
        self.commandRunner = commandRunner
        self.gitMetadataService = gitMetadataService
    }

    /// Returns the last successful content cached for the resolved repository and branch.
    public func cachedContent(for input: PullRequestWorkspaceInput) async -> PullRequestPanelContent? {
        guard let context = try? await resolvedContext(for: input) else { return nil }
        guard let content = cacheByContext[context] else { return nil }
        cacheRecency.removeAll { $0 == context }
        cacheRecency.append(context)
        return content
    }

    func storeCachedContent(_ content: PullRequestPanelContent, for context: PullRequestPanelContext) {
        cacheByContext[context] = content
        cacheRecency.removeAll { $0 == context }
        cacheRecency.append(context)
        while cacheRecency.count > Self.cacheCapacity {
            cacheByContext.removeValue(forKey: cacheRecency.removeFirst())
        }
    }

    func beginRefresh(for context: PullRequestPanelContext) -> UInt64 {
        refreshSequence &+= 1
        latestRefreshSequenceByContext[context] = refreshSequence
        return refreshSequence
    }

    func finishRefresh(_ sequence: UInt64, for context: PullRequestPanelContext) {
        guard latestRefreshSequenceByContext[context] == sequence else { return }
        latestRefreshSequenceByContext.removeValue(forKey: context)
    }

    func storeCachedContentIfLatest(
        _ content: PullRequestPanelContent,
        for context: PullRequestPanelContext,
        refreshSequence: UInt64
    ) {
        guard latestRefreshSequenceByContext[context] == refreshSequence else { return }
        storeCachedContent(content, for: context)
    }
}
