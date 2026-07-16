import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    struct AutosaveAgentIndexCache: Sendable {
        let restorableAgentIndex: RestorableAgentSessionIndex
        let processScopeFingerprint: Set<String>
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(homeDirectory: homeDirectory, fileManager: fileManager, maximumSnapshotAge: 5)
        }.value
    }

    static func loadForAutosave(
        cachedAgentIndex: AutosaveAgentIndexCache?,
        fileManager: FileManager = .default,
        processSnapshotProvider: @escaping @Sendable () -> CmuxTopProcessSnapshot = {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: 5)
        },
        processScopeFingerprintProvider: @escaping @Sendable (CmuxTopProcessSnapshot) -> Set<String> = {
            SharedLiveAgentIndexLoader.processScopeFingerprint(from: $0)
        },
        processScopeMismatchHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) async -> ProcessDetectedResumeIndexes? {
        guard let cachedAgentIndex else {
            return nil
        }
        let cachedResult: ProcessDetectedResumeIndexes? = await Task.detached(priority: .utility) {
            let processSnapshot = processSnapshotProvider()
            let currentProcessScopeFingerprint = processScopeFingerprintProvider(processSnapshot)
            guard currentProcessScopeFingerprint == cachedAgentIndex.processScopeFingerprint else {
                return nil
            }
            return loadSynchronously(
                restorableAgentIndex: cachedAgentIndex.restorableAgentIndex,
                fileManager: fileManager,
                processSnapshot: processSnapshot
            )
        }.value
        guard let cachedResult else {
            await processScopeMismatchHandler()
            return nil
        }
        return cachedResult
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
