import Foundation

actor RestorableAgentSessionIndexProvider {
    typealias ProcessDetector = @Sendable (
        _ registry: CmuxVaultAgentRegistry,
        _ fileManager: FileManager
    ) -> RestorableAgentSessionIndex.DetectedSnapshots

    private let homeDirectory: String
    private let fileManager: FileManager
    private let processDetector: ProcessDetector
    private var cachedDetectedSnapshots: RestorableAgentSessionIndex.DetectedSnapshots = [:]
    private var refreshLoopTask: Task<Void, Never>?
    private var requestedRefreshGeneration: UInt64 = 0
    private var completedRefreshGeneration: UInt64 = 0

    init(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        processDetector: @escaping ProcessDetector = RestorableAgentSessionIndexProvider.detectLiveProcessSnapshots
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.processDetector = processDetector
    }

    func indexForAutosave() async -> RestorableAgentSessionIndex {
        let homeDirectory = homeDirectory
        let fileManager = fileManager
        let detectedSnapshots = cachedDetectedSnapshots
        return await Task.detached(priority: .utility) {
            let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
            return RestorableAgentSessionIndex.load(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: detectedSnapshots
            )
        }.value
    }

    func requestProcessDetectedSnapshotRefresh() async {
        await refreshProcessDetectedSnapshots()
    }

    func refreshProcessDetectedSnapshots() async {
        requestedRefreshGeneration &+= 1
        let targetGeneration = requestedRefreshGeneration
        startRefreshLoopIfNeeded()

        while completedRefreshGeneration < targetGeneration {
            guard let refreshLoopTask else {
                startRefreshLoopIfNeeded()
                continue
            }
            await refreshLoopTask.value
        }
    }

    private func startRefreshLoopIfNeeded() {
        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { await self.runRefreshLoop() }
    }

    private func runRefreshLoop() async {
        while true {
            let refreshGeneration = requestedRefreshGeneration
            cachedDetectedSnapshots = await detectProcessSnapshots()
            completedRefreshGeneration = refreshGeneration

            guard completedRefreshGeneration < requestedRefreshGeneration else {
                refreshLoopTask = nil
                return
            }
        }
    }

    private func detectProcessSnapshots() async -> RestorableAgentSessionIndex.DetectedSnapshots {
        let homeDirectory = homeDirectory
        let fileManager = fileManager
        let processDetector = processDetector
        return await Task.detached(priority: .utility) {
            let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
            return processDetector(registry, fileManager)
        }.value
    }

    private static let detectLiveProcessSnapshots: ProcessDetector = { registry, fileManager in
        RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager
        )
    }
}
