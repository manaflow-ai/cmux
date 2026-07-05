import Foundation

struct SharedLiveAgentIndexLoader {
    typealias LoadResult = (
        index: RestorableAgentSessionIndex,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>
    )

    private let homeDirectory: String
    private let fileManager: FileManager
    private let registry: CmuxVaultAgentRegistry?
    private let processSnapshotProvider: () -> CmuxTopProcessSnapshot
    private let capturedAtProvider: () -> TimeInterval
    private let processArgumentsProvider: (Int) -> CmuxTopProcessArguments?

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
        }
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.registry = registry
        self.processSnapshotProvider = processSnapshotProvider
        self.capturedAtProvider = capturedAtProvider
        self.processArgumentsProvider = processArgumentsProvider
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
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: resolvedRegistry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: processArgumentsProvider
        )
        return (
            index: index,
            liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
            processScopeFingerprint: Self.processScopeFingerprint(from: processSnapshot)
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
}
