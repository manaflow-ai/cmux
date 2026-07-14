public import CmuxFoundation
import Foundation

/// Resolves and mutates one workspace branch's GitHub pull request exclusively through `gh`.
public actor GitHubPullRequestPanelService: PullRequestPanelServing {
    static let cacheCapacity = 32

    nonisolated let commandRunner: any CommandRunning
    nonisolated let gitMetadataService: GitMetadataService
    nonisolated let refreshLimiter: any PullRequestPanelRefreshLimiting
    var cacheByContext: [PullRequestPanelContext: PullRequestPanelContent] = [:]
    var cacheRecency: [PullRequestPanelContext] = []
    var inFlightRefreshByContext: [
        PullRequestPanelContext: (
            identifier: UInt64,
            task: Task<PullRequestPanelContent, any Error>,
            waiterIdentifiers: Set<UUID>
        )
    ] = [:]
    var refreshRequestIdentifier: UInt64 = 0
    var latestRefreshSequenceByContext: [PullRequestPanelContext: UInt64] = [:]
    var refreshSequence: UInt64 = 0

    /// Creates a GitHub CLI pull-request service.
    /// - Parameters:
    ///   - commandRunner: The async subprocess runner; tests inject a fake.
    ///   - gitMetadataService: The repository and branch resolver.
    ///   - refreshLimiter: The injected refresh-chain concurrency limit.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        gitMetadataService: GitMetadataService = GitMetadataService(),
        refreshLimiter: (any PullRequestPanelRefreshLimiting)? = nil
    ) {
        self.commandRunner = commandRunner
        self.gitMetadataService = gitMetadataService
        self.refreshLimiter = refreshLimiter ?? PullRequestPanelRefreshLimiter(limit: 2)
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

    func coalescedRefreshRequest(
        for context: PullRequestPanelContext
    ) -> (
        identifier: UInt64,
        waiterIdentifier: UUID,
        task: Task<PullRequestPanelContent, any Error>
    ) {
        let waiterIdentifier = UUID()
        if var request = inFlightRefreshByContext[context] {
            request.waiterIdentifiers.insert(waiterIdentifier)
            inFlightRefreshByContext[context] = request
            return (request.identifier, waiterIdentifier, request.task)
        }
        refreshRequestIdentifier &+= 1
        let identifier = refreshRequestIdentifier
        let limiter = refreshLimiter
        let task = Task {
            guard await limiter.acquire() else { throw CancellationError() }
            do {
                let content = try await self.performRefresh(for: context)
                await limiter.release()
                return content
            } catch {
                await limiter.release()
                throw error
            }
        }
        let request = (
            identifier: identifier,
            task: task,
            waiterIdentifiers: Set([waiterIdentifier])
        )
        inFlightRefreshByContext[context] = request
        return (identifier, waiterIdentifier, task)
    }

    func finishCoalescedRefreshWaiter(
        _ waiterIdentifier: UUID,
        requestIdentifier: UInt64,
        for context: PullRequestPanelContext
    ) {
        guard var request = inFlightRefreshByContext[context],
              request.identifier == requestIdentifier,
              request.waiterIdentifiers.remove(waiterIdentifier) != nil else { return }
        if request.waiterIdentifiers.isEmpty {
            inFlightRefreshByContext.removeValue(forKey: context)
            request.task.cancel()
        } else {
            inFlightRefreshByContext[context] = request
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
