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
    private var refreshTask: Task<RestorableAgentSessionIndex.DetectedSnapshots, Never>?

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

    func requestProcessDetectedSnapshotRefresh(reason: String) async {
        await refreshProcessDetectedSnapshots(reason: reason)
    }

    func refreshProcessDetectedSnapshots(reason: String) async {
        _ = reason
        if let refreshTask {
            cachedDetectedSnapshots = await refreshTask.value
            return
        }

        let homeDirectory = homeDirectory
        let fileManager = fileManager
        let processDetector = processDetector
        let task = Task.detached(priority: .utility) {
            let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
            return processDetector(registry, fileManager)
        }
        refreshTask = task
        cachedDetectedSnapshots = await task.value
        refreshTask = nil
    }

    private static func detectLiveProcessSnapshots(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager
    ) -> RestorableAgentSessionIndex.DetectedSnapshots {
        RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager
        )
    }
}
