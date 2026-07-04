public import Combine
public import Foundation

/// Main-actor state store for Issue Inbox.
@MainActor
public final class IssueInboxStore: ObservableObject {
    /// Current sorted issue rows.
    @Published public private(set) var items: [IssueInboxItem] = []
    /// Per-source error text from the last refresh.
    @Published public private(set) var sourceErrors: [String: String] = [:]
    /// Last successful fetch timestamp per source ID.
    @Published public private(set) var fetchedAt: [String: Date] = [:]
    /// Source IDs currently refreshing.
    @Published public private(set) var refreshing: Set<String> = []
    /// Non-fatal config warnings.
    @Published public private(set) var configWarnings: [IssueInboxConfigWarning] = []
    /// Whether the config file exists.
    @Published public private(set) var configFileExists: Bool = false
    /// Config file URL.
    @Published public private(set) var configURL: URL
    /// Configured source metadata.
    @Published public private(set) var sourceConfigs: [IssueInboxSourceConfig] = []
    /// Issue ID to workspace ID mapping.
    @Published public private(set) var spawnedWorkspaces: [String: UUID] = [:]

    private let cache: IssueInboxCache
    private let configLoader: any IssueInboxConfigLoading
    private let adapterFactory: IssueSourceAdapterFactory
    private let usesExplicitAdapters: Bool
    private var adapters: [any IssueSourceAdapter]
    private var refreshTask: Task<Void, Never>?
    private var hasLoadedState = false

    /// Creates an Issue Inbox store backed by config and cache loaders.
    ///
    /// - Parameters:
    ///   - cache: Disk cache.
    ///   - configLoader: Config loader.
    ///   - adapterFactory: Adapter factory.
    public init(
        cache: IssueInboxCache = IssueInboxCache(),
        configLoader: any IssueInboxConfigLoading = IssueInboxFileConfigLoader(),
        adapterFactory: IssueSourceAdapterFactory = IssueSourceAdapterFactory()
    ) {
        self.cache = cache
        self.configLoader = configLoader
        self.adapterFactory = adapterFactory
        self.usesExplicitAdapters = false
        self.adapters = []
        self.configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(IssueInboxFileConfigLoader.relativeConfigPath)
    }

    /// Creates an Issue Inbox store with explicit adapters for tests.
    ///
    /// - Parameters:
    ///   - adapters: Source adapters.
    ///   - sourceConfigs: Source metadata used for project roots.
    ///   - cache: Disk cache.
    ///   - configURL: Config URL exposed to setup UI.
    public init(
        adapters: [any IssueSourceAdapter],
        sourceConfigs: [IssueInboxSourceConfig],
        cache: IssueInboxCache,
        configURL: URL
    ) {
        self.cache = cache
        self.configLoader = StaticIssueInboxConfigLoader(
            result: IssueInboxConfigLoadResult(
                config: IssueInboxConfig(sources: sourceConfigs),
                warnings: [],
                fileExists: true,
                configURL: configURL
            )
        )
        self.adapterFactory = IssueSourceAdapterFactory()
        self.usesExplicitAdapters = true
        self.adapters = adapters
        self.sourceConfigs = sourceConfigs
        self.configFileExists = true
        self.configURL = configURL
    }

    deinit {
        refreshTask?.cancel()
    }

    /// Publishes cached items immediately, then starts one background refresh.
    ///
    /// - Returns: The background refresh task, if a refresh was started.
    @discardableResult
    public func load() -> Task<Void, Never>? {
        refreshTask?.cancel()
        loadConfiguration()
        loadCache()
        guard !adapters.isEmpty else {
            refreshTask = nil
            return nil
        }
        let task = Task { [weak self] in
            _ = await self?.refresh()
        }
        refreshTask = task
        return task
    }

    /// Publishes configuration and cached items without starting network refresh.
    public func loadCachedState() {
        loadConfiguration()
        loadCache()
    }

    /// Publishes cached items only when the store has not loaded yet.
    public func loadCachedStateIfNeeded() {
        guard !hasLoadedState else { return }
        loadCachedState()
    }

    /// Refreshes every configured source with per-source failure isolation.
    ///
    /// - Returns: Per-source refresh report.
    @discardableResult
    public func refresh() async -> IssueInboxRefreshReport {
        guard !adapters.isEmpty else {
            return IssueInboxRefreshReport()
        }
        let sourceIDs = Set(adapters.map(\.sourceID))
        refreshing = sourceIDs
        var report = IssueInboxRefreshReport()

        await withTaskGroup(of: IssueInboxSourceFetchOutcome.self) { group in
            for adapter in adapters {
                group.addTask {
                    do {
                        let items = try await adapter.fetchIssues()
                        return IssueInboxSourceFetchOutcome(
                            sourceID: adapter.sourceID,
                            items: items,
                            error: nil
                        )
                    } catch {
                        return IssueInboxSourceFetchOutcome(
                            sourceID: adapter.sourceID,
                            items: nil,
                            error: IssueInboxStore.describe(error)
                        )
                    }
                }
            }

            for await outcome in group {
                refreshing.remove(outcome.sourceID)
                if let fetchedItems = outcome.items {
                    replaceItems(for: outcome.sourceID, with: fetchedItems)
                    sourceErrors.removeValue(forKey: outcome.sourceID)
                    fetchedAt[outcome.sourceID] = Date()
                    report.perSource[outcome.sourceID] = IssueInboxRefreshSourceResult(count: fetchedItems.count)
                } else {
                    sourceErrors[outcome.sourceID] = outcome.error ?? "Unknown error"
                    report.perSource[outcome.sourceID] = IssueInboxRefreshSourceResult(error: sourceErrors[outcome.sourceID])
                }
            }
        }
        refreshing = []
        persistCache()
        return report
    }

    /// Returns a cached issue by ID.
    ///
    /// - Parameter issueID: Stable issue ID.
    /// - Returns: Matching item, if present.
    public func item(issueID: String) -> IssueInboxItem? {
        items.first { $0.id == issueID }
    }

    /// Returns the configured project root for an item.
    ///
    /// - Parameter item: Issue item.
    /// - Returns: Configured local project root, if present.
    public func projectRoot(for item: IssueInboxItem) -> String? {
        sourceConfigs.first { $0.sourceID == item.sourceID }?.projectRoot
    }

    /// Returns the configured source for an item.
    ///
    /// - Parameter item: Issue item.
    /// - Returns: Matching source configuration, if present.
    public func sourceConfig(for item: IssueInboxItem) -> IssueInboxSourceConfig? {
        sourceConfigs.first { $0.sourceID == item.sourceID }
    }

    /// Returns the workspace mapped to an issue ID.
    ///
    /// - Parameter issueID: Stable issue ID.
    /// - Returns: Workspace ID, if previously recorded.
    public func spawnedWorkspace(issueID: String) -> UUID? {
        spawnedWorkspaces[issueID]
    }

    /// Records a create-or-reuse workspace mapping and persists it.
    ///
    /// - Parameters:
    ///   - issueID: Stable issue ID.
    ///   - workspaceID: Spawned workspace ID.
    public func recordSpawnedWorkspace(issueID: String, workspaceID: UUID) {
        spawnedWorkspaces[issueID] = workspaceID
        persistCache()
    }

    /// Current snapshot shaped for cache and socket payloads.
    ///
    /// - Returns: Current cache snapshot.
    public func snapshot() -> IssueInboxCacheSnapshot {
        IssueInboxCacheSnapshot(
            items: items,
            fetchedAt: fetchedAt,
            spawnedWorkspaces: spawnedWorkspaces
        )
    }

    private func loadConfiguration() {
        do {
            let result = try configLoader.loadIssueInboxConfig()
            sourceConfigs = result.config.sources
            configWarnings = result.warnings
            configFileExists = result.fileExists
            configURL = result.configURL
            if !usesExplicitAdapters {
                adapters = (try? adapterFactory.adapters(for: result.config.sources)) ?? []
            }
        } catch {
            sourceConfigs = []
            configWarnings = [
                IssueInboxConfigWarning(id: "config.load", message: Self.describe(error)),
            ]
            configFileExists = false
        }
    }

    private func loadCache() {
        do {
            let snapshot = try cache.read()
            let sourceIDs = Set(sourceConfigs.map(\.sourceID))
            if sourceIDs.isEmpty {
                items = []
            } else {
                items = Self.sorted(snapshot.items.filter { sourceIDs.contains($0.sourceID) })
            }
            fetchedAt = snapshot.fetchedAt
            spawnedWorkspaces = snapshot.spawnedWorkspaces
        } catch {
            items = []
            fetchedAt = [:]
            spawnedWorkspaces = [:]
            configWarnings.append(IssueInboxConfigWarning(id: "cache.read", message: Self.describe(error)))
        }
        hasLoadedState = true
    }

    private func replaceItems(for sourceID: String, with sourceItems: [IssueInboxItem]) {
        items = Self.sorted(items.filter { $0.sourceID != sourceID } + sourceItems)
    }

    private func persistCache() {
        do {
            try cache.write(snapshot())
        } catch {
            configWarnings.append(IssueInboxConfigWarning(id: "cache.write", message: Self.describe(error)))
        }
    }

    private static func sorted(_ items: [IssueInboxItem]) -> [IssueInboxItem] {
        items.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.id < $1.id
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private struct IssueInboxSourceFetchOutcome: Sendable {
    var sourceID: String
    var items: [IssueInboxItem]?
    var error: String?
}

private struct StaticIssueInboxConfigLoader: IssueInboxConfigLoading {
    var result: IssueInboxConfigLoadResult

    func loadIssueInboxConfig() throws -> IssueInboxConfigLoadResult {
        result
    }
}
