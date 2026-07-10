import Foundation

extension RestorableAgentSessionIndex {
    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            let processSnapshot = CmuxTopProcessSnapshot.captureCached(
                includeProcessDetails: true,
                maximumAge: 5
            )
            return loadIncludingProcessDetectedSnapshotsSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                processSnapshot: processSnapshot
            )
        }.value
    }

    /// Loads with a process capture that starts after any older coordinated capture finishes.
    static func loadIncludingFreshProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            let processSnapshot = CmuxTopProcessSnapshot.captureCoordinatedFresh(
                includeProcessDetails: true
            )
            return loadIncludingProcessDetectedSnapshotsSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                processSnapshot: processSnapshot
            )
        }.value
    }

    static func loadIncludingProcessDetectedSnapshotsSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        return loadIncludingProcessDetectedSnapshotsSynchronously(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            processSnapshot: processSnapshot
        )
    }

    private static func loadIncludingProcessDetectedSnapshotsSynchronously(
        homeDirectory: String,
        fileManager: FileManager,
        processSnapshot: CmuxTopProcessSnapshot
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: processSnapshot.sampledAt.timeIntervalSince1970
        )
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
    }
}
