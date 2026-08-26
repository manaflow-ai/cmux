import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    /// When `cachedRestorableAgentIndex` is supplied (the SharedLiveAgentIndex
    /// owner's coalesced result), the hook stores are not re-read: the cached
    /// index is revalidated against a fresh-enough process snapshot and only
    /// the surface resume bindings are recomputed.
    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        cachedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                maximumSnapshotAge: 5,
                cachedRestorableAgentIndex: cachedRestorableAgentIndex,
                ttyDeviceBindings: ttyDeviceBindings
            )
        }.value
    }

    /// Loads current hook stores and captures an uncached process snapshot off-main.
    static func loadFresh(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadFreshSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                ttyDeviceBindings: ttyDeviceBindings
            )
        }.value
    }

    /// Synchronous implementation for detached loading and focused tests.
    /// Main-actor lifecycle paths must call ``loadFresh(homeDirectory:fileManager:)``.
    static func loadFreshSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
    ) -> ProcessDetectedResumeIndexes {
        loadSynchronously(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            ttyDeviceBindings: ttyDeviceBindings
        )
    }

    /// Returns the last published agent index without filesystem or process capture.
    ///
    /// This is the bounded fallback for a watchdog whose fresh capture already
    /// exceeded its deadline. Process-backed surface bindings fail closed.
    static func cached(
        restorableAgentIndex: RestorableAgentSessionIndex
    ) -> ProcessDetectedResumeIndexes {
        ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: .empty
        )
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil,
        cachedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
        let restorableAgentIndex: RestorableAgentSessionIndex
        if let cachedRestorableAgentIndex {
            restorableAgentIndex = cachedRestorableAgentIndex.revalidatingCachedProcesses(
                against: processSnapshot
            )
        } else {
            let registry = CmuxVaultAgentRegistry.load(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: registry,
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                capturedAt: capturedAt
            )
            restorableAgentIndex = RestorableAgentSessionIndex.load(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: detectedSnapshots
            )
        }
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            ttyDeviceBindings: ttyDeviceBindings
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}
