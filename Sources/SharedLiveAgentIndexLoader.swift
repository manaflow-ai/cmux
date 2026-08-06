import Darwin
import Foundation

struct SharedLiveAgentIndexLoader {
    typealias LoadResult = (
        index: RestorableAgentSessionIndex,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>,
        forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey>
    )

    private let homeDirectory: String
    private let fileManager: FileManager
    private let registry: CmuxVaultAgentRegistry?
    private let processSnapshotProvider: () -> CmuxTopProcessSnapshot
    private let capturedAtProvider: () -> TimeInterval
    private let processArgumentsProvider: @Sendable (Int) -> CmuxTopProcessArguments?
    private let processIdentityProvider: (Int) -> AgentPIDProcessIdentity?
    private let cachedAgentProcessValidator: CachedAgentProcessIdentityValidator
    private let openCodeDatabaseDescriptorPathCache: OpenCodeDatabaseDescriptorPathCache

    init(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        registry: CmuxVaultAgentRegistry? = nil,
        processSnapshotProvider: @escaping () -> CmuxTopProcessSnapshot = {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        },
        capturedAtProvider: @escaping () -> TimeInterval = {
            Date().timeIntervalSince1970
        },
        processArgumentsProvider: @escaping @Sendable (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        cachedAgentProcessValidator: CachedAgentProcessIdentityValidator = CachedAgentProcessIdentityValidator(),
        openCodeDatabaseDescriptorPathCache: OpenCodeDatabaseDescriptorPathCache? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.registry = registry
        self.processSnapshotProvider = processSnapshotProvider
        self.capturedAtProvider = capturedAtProvider
        self.processArgumentsProvider = processArgumentsProvider
        self.processIdentityProvider = processIdentityProvider
        self.cachedAgentProcessValidator = cachedAgentProcessValidator
        self.openCodeDatabaseDescriptorPathCache =
            openCodeDatabaseDescriptorPathCache
            ?? OpenCodeDatabaseDescriptorPathCache()
    }

    func loadSynchronously() -> RestorableAgentSessionIndex {
        loadResultSynchronously().index
    }

    func loadResultSynchronously() -> LoadResult {
        let resolvedRegistry = registry
            ?? CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let processSnapshot = processSnapshotProvider()
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: resolvedRegistry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAtProvider(),
            processArgumentsProvider: processArgumentsProvider
        )
        return makeLoadResult(
            registry: resolvedRegistry,
            processSnapshot: processSnapshot,
            detectedSnapshots: detectedSnapshots
        )
    }

    func loadResult(
        reuseCompletedOpenCodeDatabasePaths: Bool = true
    ) async -> LoadResult {
        await loadResult(
            restrictedTo: nil,
            reuseCompletedOpenCodeDatabasePaths: reuseCompletedOpenCodeDatabasePaths
        )
    }

    /// Revalidates one panel without resolving process metadata or provider
    /// storage for every other live agent in the app.
    func loadResult(
        for panelKey: RestorableAgentSessionIndex.PanelKey,
        reuseCompletedOpenCodeDatabasePaths: Bool = true
    ) async -> LoadResult {
        await loadResult(
            restrictedTo: panelKey,
            reuseCompletedOpenCodeDatabasePaths: reuseCompletedOpenCodeDatabasePaths
        )
    }

    private func loadResult(
        restrictedTo panelKey: RestorableAgentSessionIndex.PanelKey?,
        reuseCompletedOpenCodeDatabasePaths: Bool
    ) async -> LoadResult {
        let resolvedRegistry = registry
            ?? CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let capturedProcessSnapshot = processSnapshotProvider()
        let processSnapshot = panelKey.map {
            Self.processSnapshot(capturedProcessSnapshot, restrictedTo: $0)
        } ?? capturedProcessSnapshot
        let detectedSnapshots = await RestorableAgentSessionIndex
            .processDetectedSnapshotsCachingOpenCodeDatabasePaths(
                registry: resolvedRegistry,
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                capturedAt: capturedAtProvider(),
                reuseCompletedOpenCodeDatabasePaths: reuseCompletedOpenCodeDatabasePaths,
                openCodeDatabaseDescriptorPathCache: openCodeDatabaseDescriptorPathCache,
                processArgumentsProvider: processArgumentsProvider
            )
        return makeLoadResult(
            registry: resolvedRegistry,
            processSnapshot: processSnapshot,
            detectedSnapshots: detectedSnapshots,
            restrictToPanelKey: panelKey
        )
    }

    private func makeLoadResult(
        registry: CmuxVaultAgentRegistry,
        processSnapshot: CmuxTopProcessSnapshot,
        detectedSnapshots: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry],
        restrictToPanelKey: RestorableAgentSessionIndex.PanelKey? = nil
    ) -> LoadResult {
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: processArgumentsProvider,
            processIdentityProvider: processIdentityProvider,
            restrictToPanelKey: restrictToPanelKey
        )
        return (
            index: index,
            liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
            processScopeFingerprint: Self.processScopeFingerprint(from: processSnapshot),
            forkValidatedPanels: Self.forkValidatedPanels(
                in: index,
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: processIdentityProvider,
                validator: cachedAgentProcessValidator
            )
        )
    }

    private static func processSnapshot(
        _ snapshot: CmuxTopProcessSnapshot,
        restrictedTo panelKey: RestorableAgentSessionIndex.PanelKey
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: snapshot.processesByPID.values.filter { process in
                process.cmuxWorkspaceID == panelKey.workspaceId
                    && process.cmuxSurfaceID == panelKey.panelId
            },
            sampledAt: snapshot.sampledAt,
            includesProcessDetails: true
        )
    }

    static func processScopeFingerprint(from snapshot: CmuxTopProcessSnapshot) -> Set<String> {
        Set(snapshot.cmuxScopedProcesses().map { process in
            [
                process.cmuxWorkspaceID?.uuidString ?? "",
                process.cmuxSurfaceID?.uuidString ?? "",
                String(process.pid),
                String(process.parentPID)
            ].joined(separator: "|")
        })
    }

    private static func forkValidatedPanels(
        in index: RestorableAgentSessionIndex,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        validator: CachedAgentProcessIdentityValidator
    ) -> Set<RestorableAgentSessionIndex.PanelKey> {
        Set(index.forkValidationEntries().compactMap { key, entry in
            forkEntryIsValidForForkAvailability(
                entry,
                panelKey: key,
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: processIdentityProvider,
                validator: validator
            ) ? key : nil
        })
    }

    private static func forkEntryIsValidForForkAvailability(
        _ entry: RestorableAgentSessionIndex.Entry,
        panelKey: RestorableAgentSessionIndex.PanelKey,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        validator: CachedAgentProcessIdentityValidator
    ) -> Bool {
        guard !entry.agentProcessIDs.isEmpty else { return true }
        for processID in entry.agentProcessIDs {
            guard let expectedIdentity = entry.agentProcessIdentities[processID],
                  processIdentityProvider(processID) == expectedIdentity,
                  let process = processArgumentsProvider(processID),
                  process.matchesCMUXScope(
                      workspaceId: panelKey.workspaceId,
                      surfaceId: panelKey.panelId
                  ),
                  validator.currentProcess(process, matches: entry.snapshot) else {
                return false
            }
        }
        return true
    }
}
