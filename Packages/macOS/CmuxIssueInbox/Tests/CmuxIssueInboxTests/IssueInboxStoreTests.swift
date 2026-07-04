@testable import CmuxIssueInbox
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct IssueInboxStoreTests {
    @Test
    func cachedItemsPublishBeforeSlowRefreshCompletes() async throws {
        let temp = try TemporaryIssueInboxDirectory()
        let cache = IssueInboxCache(directoryURL: temp.url)
        let cached = Self.item(id: "github:manaflow-ai/cmux:1", source: "manaflow-ai/cmux", number: "1", title: "Cached")
        try cache.write(IssueInboxCacheSnapshot(items: [cached]))
        let gate = AdapterGate()
        let refreshed = Self.item(id: "github:manaflow-ai/cmux:2", source: "manaflow-ai/cmux", number: "2", title: "Fresh")
        let store = IssueInboxStore(
            adapters: [FakeIssueSourceAdapter(sourceID: "github:manaflow-ai/cmux", displayName: "cmux") {
                try await gate.wait()
            }],
            sourceConfigs: [IssueInboxSourceConfig(type: .github, repo: "manaflow-ai/cmux")],
            cache: cache,
            configURL: temp.url.appendingPathComponent("issue-inbox.json")
        )

        let task = store.load()

        #expect(store.items == [cached])
        await gate.resume(returning: [refreshed])
        await task?.value
        #expect(store.items == [refreshed])
    }

    @Test
    func failingSourceKeepsCachedItemsWhileOtherSourceUpdates() async throws {
        let temp = try TemporaryIssueInboxDirectory()
        let cache = IssueInboxCache(directoryURL: temp.url)
        let cachedGitHub = Self.item(id: "github:manaflow-ai/cmux:1", source: "manaflow-ai/cmux", number: "1", title: "Cached GitHub")
        let cachedLinear = Self.linearItem(id: "linear:ENG:ENG-1", number: "ENG-1", title: "Cached Linear")
        try cache.write(IssueInboxCacheSnapshot(items: [cachedGitHub, cachedLinear]))
        let freshLinear = Self.linearItem(id: "linear:ENG:ENG-2", number: "ENG-2", title: "Fresh Linear")
        let store = IssueInboxStore(
            adapters: [
                FakeIssueSourceAdapter(sourceID: "github:manaflow-ai/cmux", displayName: "cmux") {
                    throw TestAdapterError()
                },
                FakeIssueSourceAdapter(sourceID: "linear:ENG", displayName: "Linear ENG") {
                    [freshLinear]
                },
            ],
            sourceConfigs: [
                IssueInboxSourceConfig(type: .github, repo: "manaflow-ai/cmux"),
                IssueInboxSourceConfig(type: .linear, teamKey: "ENG"),
            ],
            cache: cache,
            configURL: temp.url.appendingPathComponent("issue-inbox.json")
        )

        let task = store.load()
        await task?.value

        #expect(store.items.contains(cachedGitHub))
        #expect(store.items.contains(freshLinear))
        #expect(!store.items.contains(cachedLinear))
        #expect(store.sourceErrors["github:manaflow-ai/cmux"] != nil)
        #expect(store.sourceErrors["linear:ENG"] == nil)
    }

    @Test
    func cacheRoundTripsThroughDisk() throws {
        let temp = try TemporaryIssueInboxDirectory()
        let cache = IssueInboxCache(directoryURL: temp.url)
        let workspaceID = UUID()
        let item = Self.item(id: "github:manaflow-ai/cmux:9", source: "manaflow-ai/cmux", number: "9", title: "Round trip")
        let fetchedAt = Date(timeIntervalSince1970: 1_783_000_000)

        try cache.write(IssueInboxCacheSnapshot(
            items: [item],
            fetchedAt: ["github:manaflow-ai/cmux": fetchedAt],
            spawnedWorkspaces: [item.id: workspaceID]
        ))
        let decoded = try cache.read()

        #expect(decoded.items == [item])
        #expect(decoded.fetchedAt["github:manaflow-ai/cmux"] == fetchedAt)
        #expect(decoded.spawnedWorkspaces[item.id] == workspaceID)
    }

    @Test
    func loadCachedStateIfNeededKeepsLoadedMemoryState() throws {
        let temp = try TemporaryIssueInboxDirectory()
        let cache = IssueInboxCache(directoryURL: temp.url)
        let cached = Self.item(id: "github:manaflow-ai/cmux:1", source: "manaflow-ai/cmux", number: "1", title: "Cached")
        let diskReplacement = Self.item(id: "github:manaflow-ai/cmux:2", source: "manaflow-ai/cmux", number: "2", title: "Disk Replacement")
        try cache.write(IssueInboxCacheSnapshot(items: [cached]))
        let store = IssueInboxStore(
            adapters: [],
            sourceConfigs: [IssueInboxSourceConfig(type: .github, repo: "manaflow-ai/cmux")],
            cache: cache,
            configURL: temp.url.appendingPathComponent("issue-inbox.json")
        )

        store.load()
        try cache.write(IssueInboxCacheSnapshot(items: [diskReplacement]))
        store.loadCachedStateIfNeeded()

        #expect(store.items == [cached])
    }

    @Test
    func mergeReplacesOnlySuccessfulSource() async throws {
        let temp = try TemporaryIssueInboxDirectory()
        let cache = IssueInboxCache(directoryURL: temp.url)
        let oldGitHub = Self.item(id: "github:manaflow-ai/cmux:1", source: "manaflow-ai/cmux", number: "1", title: "Old GitHub")
        let oldLinear = Self.linearItem(id: "linear:ENG:ENG-1", number: "ENG-1", title: "Old Linear")
        try cache.write(IssueInboxCacheSnapshot(items: [oldGitHub, oldLinear]))
        let newGitHub = Self.item(id: "github:manaflow-ai/cmux:2", source: "manaflow-ai/cmux", number: "2", title: "New GitHub")
        let store = IssueInboxStore(
            adapters: [FakeIssueSourceAdapter(sourceID: "github:manaflow-ai/cmux", displayName: "cmux") {
                [newGitHub]
            }],
            sourceConfigs: [
                IssueInboxSourceConfig(type: .github, repo: "manaflow-ai/cmux"),
                IssueInboxSourceConfig(type: .linear, teamKey: "ENG"),
            ],
            cache: cache,
            configURL: temp.url.appendingPathComponent("issue-inbox.json")
        )

        let task = store.load()
        await task?.value

        #expect(store.items.contains(newGitHub))
        #expect(store.items.contains(oldLinear))
        #expect(!store.items.contains(oldGitHub))
    }

    private static func item(
        id: String,
        source: String,
        number: String,
        title: String
    ) -> IssueInboxItem {
        IssueInboxItem(
            id: id,
            provider: .github,
            sourceURL: URL(string: "https://github.com/\(source)/issues/\(number)")!,
            title: title,
            status: .open,
            providerState: "open",
            updatedAt: Date(timeIntervalSince1970: Double(number) ?? 1),
            repoOrProject: source,
            number: number
        )
    }

    private static func linearItem(id: String, number: String, title: String) -> IssueInboxItem {
        IssueInboxItem(
            id: id,
            provider: .linear,
            sourceURL: URL(string: "https://linear.app/cmux/issue/\(number)")!,
            title: title,
            status: .open,
            providerState: "started",
            updatedAt: Date(timeIntervalSince1970: 100),
            repoOrProject: "ENG",
            number: number
        )
    }
}

private struct FakeIssueSourceAdapter: IssueSourceAdapter {
    var sourceID: String
    var displayName: String
    var fetch: @Sendable () async throws -> [IssueInboxItem]

    func fetchIssues() async throws -> [IssueInboxItem] {
        try await fetch()
    }
}

private actor AdapterGate {
    private var continuation: CheckedContinuation<[IssueInboxItem], any Error>?
    private var pending: Result<[IssueInboxItem], any Error>?

    func wait() async throws -> [IssueInboxItem] {
        if let pending {
            self.pending = nil
            return try pending.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(returning items: [IssueInboxItem]) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: items)
        } else {
            pending = .success(items)
        }
    }
}

private struct TemporaryIssueInboxDirectory {
    var url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-issue-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private struct TestAdapterError: Error {}
