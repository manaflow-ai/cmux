import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                maximumSnapshotAge: 5,
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

    /// Loads fresh process state with a bounded lifecycle deadline.
    @MainActor
    static func loadFreshWithDeadline(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        deadline: Duration = .seconds(5),
        onWorkerCreated: @escaping @MainActor @Sendable (
            Task<ProcessDetectedResumeIndexes, Never>
        ) -> Void = { _ in },
        sleepUntilDeadline: @escaping @Sendable (Duration) async -> Bool = { duration in
            do {
                // Genuine recovery deadline; cancellation returns the fail-closed result.
                try await ContinuousClock().sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) async -> ProcessDetectedResumeIndexes? {
        let (workerFinished, workerFinishedContinuation) =
            AsyncStream<Void>.makeStream()
        // The synchronous worker cannot be interrupted in the middle of a
        // process/filesystem call. Its owner retains the handle until it
        // finishes so a later recovery pass cannot overlap another scan.
        let worker = Task.detached(priority: .utility) {
            let result = loadFreshSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                ttyDeviceBindings: ttyDeviceBindings
            )
            workerFinishedContinuation.yield(())
            return result
        }
        onWorkerCreated(worker)

        // Race two cancellable child tasks. The worker signal child is separate
        // from the synchronous worker, so canceling the race never waits for a
        // timed-out process/filesystem scan.
        return await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var iterator = workerFinished.makeAsyncIterator()
                _ = await iterator.next()
                return 0 // worker finished
            }
            group.addTask {
                await sleepUntilDeadline(deadline) ? 1 : 2
            }
            let winner = await group.next() ?? 2
            workerFinishedContinuation.finish()
            group.cancelAll()
            guard winner == 0 else {
                worker.cancel()
                return nil
            }
            return await worker.value
        }
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
