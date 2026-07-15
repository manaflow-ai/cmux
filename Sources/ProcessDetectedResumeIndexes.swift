import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(homeDirectory: homeDirectory, fileManager: fileManager, maximumSnapshotAge: 5)
        }.value
    }

    static func loadForAutosave(
        cachedRestorableAgentIndex: RestorableAgentSessionIndex?,
        fileManager: FileManager = .default,
        processSnapshotProvider: @escaping @Sendable () -> CmuxTopProcessSnapshot = {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: 5)
        },
        fullLoad: @escaping @Sendable () async -> ProcessDetectedResumeIndexes = {
            await ProcessDetectedResumeIndexes.load()
        }
    ) async -> ProcessDetectedResumeIndexes {
        guard let cachedRestorableAgentIndex else {
            return await fullLoad()
        }
        return await Task.detached(priority: .utility) {
            loadSynchronously(
                restorableAgentIndex: cachedRestorableAgentIndex,
                fileManager: fileManager,
                processSnapshot: processSnapshotProvider()
            )
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
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

    private static func loadSynchronously(
        restorableAgentIndex: RestorableAgentSessionIndex,
        fileManager: FileManager,
        processSnapshot: CmuxTopProcessSnapshot
    ) -> ProcessDetectedResumeIndexes {
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: Date().timeIntervalSince1970
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(
                bindingsByPanel: detectedBindings.mapValues(\.binding)
            )
        )
    }
}
