import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        snapshotStore: CmuxTopProcessSnapshotStore = .shared
    ) async -> ProcessDetectedResumeIndexes {
        let processSnapshot = await snapshotStore.snapshot(
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

    /// Termination-only fallback. App shutdown must persist the final restorable
    /// state before returning to AppKit, so this one raw capture cannot await the
    /// actor; the compatibility seam records it in the shared proof metrics.
    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> ProcessDetectedResumeIndexes {
        let processSnapshot = CmuxTopProcessSnapshot.captureSynchronouslyForCompatibility(
            includeProcessDetails: true
        )
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
