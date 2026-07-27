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
    private let injectedProcessArgumentsProvider: ((Int) -> CmuxTopProcessArguments?)?
    private let processArgumentBytesProvider: (Int) -> [UInt8]?
    private let processArgumentsDecoder: ([UInt8]) -> CmuxTopProcessArguments?
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
        processArgumentsProvider: ((Int) -> CmuxTopProcessArguments?)? = nil,
        processArgumentBytesProvider: @escaping (Int) -> [UInt8]? = {
            CmuxTopProcessSnapshot.kernProcArgsBytes(for: $0)
        },
        processArgumentsDecoder: @escaping ([UInt8]) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: $0)
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
        self.injectedProcessArgumentsProvider = processArgumentsProvider
        self.processArgumentsProvider = processArgumentsProvider ?? {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
        self.processArgumentBytesProvider = processArgumentBytesProvider
        self.processArgumentsDecoder = processArgumentsDecoder
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
            processArgumentsProvider: injectedProcessArgumentsProvider,
            processArgumentBytesProvider: processArgumentBytesProvider,
            processArgumentsDecoder: processArgumentsDecoder
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: resolvedRegistry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: processArgumentsProvider,
            processIdentityProvider: processIdentityProvider
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
