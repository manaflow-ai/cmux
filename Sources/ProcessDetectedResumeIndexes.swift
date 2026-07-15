import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    struct ProcessDetectedAgentFingerprint: Equatable, Sendable {
        static let empty = ProcessDetectedAgentFingerprint(entries: [])

        struct Entry: Equatable, Sendable {
            let panelKey: RestorableAgentSessionIndex.PanelKey
            let snapshot: SessionRestorableAgentSnapshot
            let processIDs: Set<Int>
            let agentProcessIDs: Set<Int>
            let sessionIDSource: RestorableAgentSessionIndex.ProcessDetectedSessionIDSource
        }

        let entries: [Entry]
    }

    struct AutosaveAgentIndexCache: Sendable {
        let restorableAgentIndex: RestorableAgentSessionIndex
        let processDetectedAgentFingerprint: ProcessDetectedAgentFingerprint
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
        processDetectedAgentFingerprintProvider: (
            @Sendable (CmuxTopProcessSnapshot) -> ProcessDetectedAgentFingerprint
        )? = nil,
        fullLoad: @escaping @Sendable () async -> ProcessDetectedResumeIndexes = {
            await ProcessDetectedResumeIndexes.load()
        }
    ) async -> ProcessDetectedResumeIndexes {
        guard let cachedAgentIndex else {
            return await fullLoad()
        }
        let fingerprintProvider = processDetectedAgentFingerprintProvider ?? { processSnapshot in
            let registry = CmuxVaultAgentRegistry.load(fileManager: fileManager)
            let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: registry,
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                capturedAt: Date().timeIntervalSince1970
            )
            return processDetectedAgentFingerprint(from: detectedSnapshots)
        }
        let cachedResult = await Task.detached(priority: .utility) {
            let processSnapshot = processSnapshotProvider()
            guard fingerprintProvider(processSnapshot) == cachedAgentIndex.processDetectedAgentFingerprint else {
                return nil
            }
            return loadSynchronously(
                restorableAgentIndex: cachedAgentIndex.restorableAgentIndex,
                fileManager: fileManager,
                processSnapshot: processSnapshot
            )
        }.value
        if let cachedResult {
            return cachedResult
        }
        return await fullLoad()
    }

    static func processDetectedAgentFingerprint(
        from snapshots: [
            RestorableAgentSessionIndex.PanelKey:
                RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry
        ]
    ) -> ProcessDetectedAgentFingerprint {
        // detected.updatedAt is the scan time. It changes on every pass but does
        // not participate in RestorableAgentSessionIndex's resolved entries.
        let entries = snapshots.map { panelKey, detected in
            ProcessDetectedAgentFingerprint.Entry(
                panelKey: panelKey,
                snapshot: detected.snapshot,
                processIDs: detected.processIDs,
                agentProcessIDs: detected.agentProcessIDs,
                sessionIDSource: detected.sessionIDSource
            )
        }.sorted { lhs, rhs in
            let lhsWorkspace = lhs.panelKey.workspaceId.uuidString
            let rhsWorkspace = rhs.panelKey.workspaceId.uuidString
            if lhsWorkspace != rhsWorkspace {
                return lhsWorkspace < rhsWorkspace
            }
            return lhs.panelKey.panelId.uuidString < rhs.panelKey.panelId.uuidString
        }
        return ProcessDetectedAgentFingerprint(entries: entries)
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
