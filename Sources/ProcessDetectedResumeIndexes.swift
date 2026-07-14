import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    init(
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) {
        self.restorableAgentIndex = restorableAgentIndex
        self.surfaceResumeBindingIndex = surfaceResumeBindingIndex
    }

    init(_ loadResult: SharedLiveAgentIndexLoader.LoadResult) {
        self.init(
            restorableAgentIndex: loadResult.index,
            surfaceResumeBindingIndex: loadResult.surfaceResumeBindingIndex
        )
    }

    @MainActor
    static func load(
        maximumAge: TimeInterval = 60
    ) async -> ProcessDetectedResumeIndexes? {
        await load(coordinatedBy: .shared, maximumAge: maximumAge)
    }

    @MainActor
    static func load(
        coordinatedBy sharedIndex: SharedLiveAgentIndex,
        maximumAge: TimeInterval = 60
    ) async -> ProcessDetectedResumeIndexes? {
        await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: maximumAge)
    }

    @MainActor
    static func loadCapturedAfterRequest() async -> ProcessDetectedResumeIndexes? {
        await loadCapturedAfterRequest(coordinatedBy: .shared)
    }

    @MainActor
    static func loadCapturedAfterRequest(
        coordinatedBy sharedIndex: SharedLiveAgentIndex
    ) async -> ProcessDetectedResumeIndexes? {
        await sharedIndex.resumeIndexesCapturedAfterRequest()
    }

    /// One-off compatibility entry point for callers with an isolated process
    /// snapshot store. Normal runtime consumers share `SharedLiveAgentIndex`.
    static func load(
        homeDirectory: String,
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
    /// state before returning to AppKit, so this raw capture cannot await the actor.
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
        let capturedAt = processSnapshot.sampledAt.timeIntervalSince1970
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
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(
                bindingsByPanel: detectedBindings.mapValues(\.binding)
            )
        )
    }
}
