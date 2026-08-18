import CmuxCore
import CmuxAgentManifests
import CmuxFoundation
import Foundation
import OSLog

/// Notification posted after a manifest generation is accepted. Consumers
/// invalidate their liveness/reconciliation snapshots instead of installing a
/// second watcher of the user directory.
extension Notification.Name {
    static let cmuxAgentManifestsDidReload = Notification.Name("com.cmux.agent-manifests.did-reload")
}

/// App composition root for the data-driven agent catalog. The actor owns the
/// one reload path; the CLI and the file watcher both call ``reload()`` on the
/// same live store. Detection consumers remain value-based and can safely
/// retain a snapshot while a later generation is loaded.
actor CmuxAgentManifestRuntime {
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "AgentManifestRuntime")

    private let userDirectory: URL
    private let fileManager: FileManager
    private var store: CmuxAgentManifestStore?
    private var watcher: FileWatcher?
    private var updatesTask: Task<Void, Never>?
    private var startupError: CmuxAgentManifestLoadError?
    private var lastPublishedGeneration: UInt64?

    init(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        let normalizedHomeDirectory = (homeDirectory as NSString).standardizingPath
        self.userDirectory = CmuxAgentManifestLoader.defaultUserDirectory(
            homeDirectory: URL(fileURLWithPath: normalizedHomeDirectory)
        )
        self.fileManager = fileManager
    }

    func start() async {
        guard store == nil else { return }
        do {
            try fileManager.createDirectory(
                at: userDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let loader = try CmuxAgentManifestLoader.bundled(
                userDirectory: userDirectory,
                fileManager: fileManager
            )
            // Keep bundled behavior available when an override is malformed.
            // The watcher must still start so the next atomic save can recover
            // without restarting cmux.
            let initialOutcome = try loader.loadWithBundledFallback()
            let liveStore = try CmuxAgentManifestStore(
                loader: loader,
                initialSnapshot: initialOutcome.snapshot,
                initialError: initialOutcome.rejectedOverrideError
            )
            // Editors commonly implement one save as create/write/rename.
            // Coalesce that burst before decoding the whole catalog while the
            // watcher still remains fully event-driven.
            let fileWatcher = FileWatcher(
                path: userDirectory.path,
                throttle: .milliseconds(250)
            )
            store = liveStore
            watcher = fileWatcher
            startupError = nil
            publish(initialOutcome.snapshot)
            updatesTask?.cancel()
            updatesTask = Task { [weak self, updates = liveStore.updates] in
                for await snapshot in updates {
                    guard !Task.isCancelled else { return }
                    await self?.publish(snapshot)
                }
            }
            await liveStore.startWatching(events: fileWatcher.events)
        } catch let error as CmuxAgentManifestLoadError {
            startupError = error
            Self.logger.error("Agent manifest runtime failed to start: \(error.localizedDescription, privacy: .public)")
        } catch {
            let wrapped = CmuxAgentManifestLoadError.invalidFile(
                path: userDirectory.path,
                reason: error.localizedDescription
            )
            startupError = wrapped
            Self.logger.error("Agent manifest runtime failed to start: \(wrapped.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        updatesTask?.cancel()
        updatesTask = nil
        await store?.stopWatching()
        await watcher?.stop()
        store = nil
        watcher = nil
        lastPublishedGeneration = nil
    }

    func snapshot() async -> CmuxAgentManifestSnapshot? {
        await start()
        return await store?.snapshot()
    }

    func state() async -> (
        snapshot: CmuxAgentManifestSnapshot?,
        error: CmuxAgentManifestLoadError?
    ) {
        await start()
        guard let store else { return (nil, startupError) }
        let snapshot = await store.snapshot()
        let reloadError = await store.reloadError()
        return (snapshot, startupError ?? reloadError)
    }

    func reload() async -> Result<CmuxAgentManifestSnapshot, CmuxAgentManifestLoadError> {
        await start()
        return await reloadFromDisk()
    }

    private func reloadFromDisk() async -> Result<CmuxAgentManifestSnapshot, CmuxAgentManifestLoadError> {
        guard let store else {
            return .failure(
                startupError ?? .invalidFile(
                    path: userDirectory.path,
                    reason: String(
                        localized: "agentManifest.validation.runtimeUnavailable",
                        defaultValue: "Manifest runtime is unavailable"
                    )
                )
            )
        }
        let result = await store.reload()
        switch result {
        case .success:
            startupError = nil
        case .failure:
            break
        }
        return result
    }

    private func publish(_ snapshot: CmuxAgentManifestSnapshot) {
        let generationChanged = lastPublishedGeneration != snapshot.generation
        lastPublishedGeneration = snapshot.generation
        guard generationChanged else { return }
        NotificationCenter.default.post(
            name: .cmuxAgentManifestsDidReload,
            object: snapshot
        )
    }
}
