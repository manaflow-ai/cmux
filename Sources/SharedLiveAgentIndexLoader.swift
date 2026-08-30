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
    private let processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    private let processIdentityProvider: (Int) -> AgentPIDProcessIdentity?
    private let cachedAgentProcessValidator: CachedAgentProcessIdentityValidator

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
        processArgumentsProvider: @escaping (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        cachedAgentProcessValidator: CachedAgentProcessIdentityValidator = CachedAgentProcessIdentityValidator()
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.registry = registry
        self.processSnapshotProvider = processSnapshotProvider
        self.capturedAtProvider = capturedAtProvider
        self.processArgumentsProvider = processArgumentsProvider
        self.processIdentityProvider = processIdentityProvider
        self.cachedAgentProcessValidator = cachedAgentProcessValidator
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
        let hibernationProcessScopes = detectedSnapshots.mapValues { detected in
            processSnapshot.agentHibernationProcessScope(
                panelProcessIDs: detected.processIDs,
                agentProcessIDs: detected.agentProcessIDs
            )
        }
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: resolvedRegistry,
            detectedSnapshots: detectedSnapshots,
            hibernationProcessScopes: hibernationProcessScopes,
            processArgumentsProvider: processArgumentsProvider,
            processIdentityProvider: processIdentityProvider
        )
        return (
            index: index,
            liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
            processScopeFingerprint: Self.processScopeFingerprint(
                from: processSnapshot,
                hibernationProcessScopes: hibernationProcessScopes
            ).union(Self.terminationProcessIdentityFingerprint(from: index)),
            forkValidatedPanels: Self.forkValidatedPanels(
                in: index,
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: processIdentityProvider,
                validator: cachedAgentProcessValidator
            )
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

    /// Fingerprints the process scope and generation metadata consumed by
    /// hibernation safety checks, so cache reloads publish scope changes even
    /// when the cmux-attributed process set is unchanged.
    static func processScopeFingerprint(
        from snapshot: CmuxTopProcessSnapshot,
        hibernationProcessScopes: [
            RestorableAgentSessionIndex.PanelKey:
                RestorableAgentSessionIndex.HibernationProcessScope
        ]
    ) -> Set<String> {
        var fingerprint = processScopeFingerprint(from: snapshot)
        fingerprint.formUnion(hibernationProcessScopes.map { key, scope in
            [
                "hibernation",
                key.workspaceId.uuidString,
                key.panelId.uuidString,
                boundedProcessIDFingerprint(scope.panelProcessIDs),
                boundedProcessIDFingerprint(scope.terminationProcessIDs),
                scope.containsUnrelatedProcess ? "unrelated" : "exclusive"
            ].joined(separator: "|")
        })
        return fingerprint
    }

    /// Avoids sorting or materializing oversized scopes that cannot be signaled.
    private static func boundedProcessIDFingerprint(_ processIDs: Set<Int>) -> String {
        guard processIDs.count <=
            AgentHibernationController.maximumScopedProcessTerminationCount else {
            return "over-limit:\(processIDs.count)"
        }
        return processIDs.sorted().map(String.init).joined(separator: ",")
    }

    /// Fingerprints every authorized termination generation so a PID reuse or
    /// transient identity lookup change replaces the cached index.
    private static func terminationProcessIdentityFingerprint(
        from index: RestorableAgentSessionIndex
    ) -> Set<String> {
        Set(index.forkValidationEntries().compactMap { key, entry in
            guard entry.processLiveness == .running,
                  !entry.terminationProcessIDs.isEmpty else {
                return nil
            }
            let identities: String
            if entry.terminationProcessIDs.count >
                AgentHibernationController.maximumScopedProcessTerminationCount {
                identities = "over-limit:\(entry.terminationProcessIDs.count)"
            } else {
                identities = entry.terminationProcessIdentities
                    .sorted { $0.key < $1.key }
                    .map { processID, identity in
                        "\(processID):\(identity.startSeconds):\(identity.startMicroseconds)"
                    }
                    .joined(separator: ",")
            }
            return [
                "hibernation-identities",
                key.workspaceId.uuidString,
                key.panelId.uuidString,
                boundedProcessIDFingerprint(entry.terminationProcessIDs),
                identities
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
