import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        let processSnapshot = await CmuxTopProcessSnapshotStore.shared.snapshot(
            requirements: [.processDetails, .cmuxScope],
            maximumAge: 5,
            consumer: .processDetectedResume
        )
        return await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                processSnapshot: processSnapshot
            )
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil
    ) -> ProcessDetectedResumeIndexes {
        let processSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
        return loadSynchronously(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            processSnapshot: processSnapshot
        )
    }

    static func loadSynchronously(
        homeDirectory: String,
        fileManager: FileManager,
        processSnapshot: CmuxTopProcessSnapshot
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}
