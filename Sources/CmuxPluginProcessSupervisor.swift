import CmuxExtensionKit
import CmuxSettings
import Darwin
import Foundation
import OSLog

/// Centralizes the app-wide unified-logging subsystem identifier.
struct Logging {
    private init() {}

    /// The bundle-specific subsystem used by app-owned loggers.
    nonisolated static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
    }
}

nonisolated let pluginProcessLogger = Logger(
    subsystem: Logging.subsystem,
    category: "Plugins"
)

/// Owns the child processes for enabled, manifest-declared plugins.
///
/// Plugins communicate through the existing control socket rather than a
/// Swift-specific IPC channel. The supervisor only supplies the socket path,
/// an in-memory session token, and the manifest location through the child
/// environment. This keeps plugins language-neutral and makes process launch
/// a single, testable composition-root concern.
@MainActor
final class CmuxPluginProcessSupervisor {
    let environmentKeys = CmuxPluginEnvironment()
    let snapshotter: CmuxPluginExecutionSnapshotter

    struct RunningProcess {
        let process: Process
        let fingerprint: String
        let sessionToken: String
        let socketPath: String
        let processID: pid_t
        let processGroupID: pid_t
        let authorizationIdentity: CmuxPluginProcessIdentity
        let containment: CmuxPluginProcessContainment
        let snapshot: CmuxPluginExecutionSnapshot
        let integrityMonitor: CmuxPluginSnapshotIntegrityMonitor
        let integrityTask: Task<Void, Never>
    }

    var processes: [String: RunningProcess] = [:]
    var launchingPluginIDs: Set<String> = []
    var pendingReconciliationPluginIDs: Set<String> = []
    var restartTasks: [String: Task<Void, Never>] = [:]
    var restartAttempts: [String: Int] = [:]
    var restartFingerprints: [String: String] = [:]

    init(snapshotter: CmuxPluginExecutionSnapshotter? = nil) {
        CmuxPluginProcessContainment.reapStaleMarkers()
        self.snapshotter = snapshotter ?? CmuxPluginExecutionSnapshotter()
    }

    /// Reconciles child processes with the registry's authoritative snapshot.
    ///
    /// Disabled, revoked, removed, or changed plugins are terminated before a
    /// replacement is launched. A failed launch is reported through the
    /// supplied callback and never escapes into the app's launch path.
    func reconcile(
        snapshot: CmuxPluginRegistrySnapshot,
        sessionTokens: [String: String],
        socketPath: String,
        generation: UInt64,
        allowLaunch: Bool = true,
        runtime: CmuxPluginRuntime,
        reportError: @escaping @Sendable (String, String?) -> Void
    ) async {
        let desired = Dictionary(snapshot.plugins.map {
            ($0.plugin.manifest.id, $0)
        }, uniquingKeysWith: { _, replacement in replacement })
        let desiredPluginIDs = Set(desired.keys)
        for pluginID in Set(restartAttempts.keys).union(restartFingerprints.keys)
        where !desiredPluginIDs.contains(pluginID) {
            restartTasks.removeValue(forKey: pluginID)?.cancel()
            restartAttempts[pluginID] = nil
            restartFingerprints[pluginID] = nil
        }

        // Collect first: mutating a dictionary while iterating its storage is
        // undefined and can leave a stale child running after a revoke.
        let staleIDs = processes.compactMap { pluginID, running in
            guard let descriptor = desired[pluginID],
                  descriptor.isEnabled,
                  descriptor.plugin.manifestFingerprint == running.fingerprint,
                  sessionTokens[pluginID] == running.sessionToken,
                  running.socketPath == socketPath else {
                return pluginID
            }
            return nil
        }
        for pluginID in staleIDs {
            guard let running = processes.removeValue(forKey: pluginID) else { continue }
            stop(pluginID: pluginID, running: running, runtime: runtime)
        }

        guard allowLaunch else { return }

        for descriptor in snapshot.plugins where descriptor.isEnabled {
            guard !Task.isCancelled,
                  runtime.processReconciliationIsAllowed(generation: generation) else {
                return
            }
            let pluginID = descriptor.plugin.manifest.id
            let fingerprint = descriptor.plugin.manifestFingerprint
            if let previousFingerprint = restartFingerprints[pluginID],
               previousFingerprint != fingerprint {
                restartTasks.removeValue(forKey: pluginID)?.cancel()
                restartAttempts[pluginID] = nil
                restartFingerprints[pluginID] = nil
            }
            guard restartTasks[pluginID] == nil else { continue }
            guard processes[pluginID] == nil else { continue }
            guard launchingPluginIDs.insert(pluginID).inserted else {
                pendingReconciliationPluginIDs.insert(pluginID)
                continue
            }
            do {
                // A second same-generation reconciliation can arrive while
                // snapshot verification awaits disk. Claiming the id before
                // that await keeps only one launch path eligible; the claim is
                // released on every success, failure, or cancellation path.
                defer {
                    launchingPluginIDs.remove(pluginID)
                    if pendingReconciliationPluginIDs.remove(pluginID) != nil {
                        // The newer reconciliation skipped this in-flight claim.
                        // Queue one bounded latest-state reload after the claim
                        // releases so an enabled plugin cannot remain unlaunched.
                        runtime.reload()
                    }
                }
                guard let sessionToken = sessionTokens[pluginID] else {
                    reportError(
                        pluginID,
                        String(
                            localized: "settings.plugins.error.authorization",
                            defaultValue: "The plugin session could not be authorized."
                        )
                    )
                    continue
                }
                let executionSnapshot: CmuxPluginExecutionSnapshot
                do {
                    executionSnapshot = try await snapshotter.makeSnapshot(for: descriptor.plugin)
                } catch {
                    reportError(
                        pluginID,
                        String(
                            localized: "settings.plugins.error.launch",
                            defaultValue: "The plugin could not be launched."
                        )
                    )
                    continue
                }
                guard executionSnapshot.fingerprint == descriptor.plugin.manifestFingerprint else {
                    await snapshotter.remove(executionSnapshot)
                    reportError(
                        pluginID,
                        String(
                            localized: "settings.plugins.error.launch",
                            defaultValue: "The plugin could not be launched."
                        )
                    )
                    continue
                }
                guard !Task.isCancelled,
                      runtime.processReconciliationIsAllowed(generation: generation) else {
                    await snapshotter.remove(executionSnapshot)
                    return
                }
                await launch(
                    descriptor: descriptor,
                    executionSnapshot: executionSnapshot,
                    sessionToken: sessionToken,
                    socketPath: socketPath,
                    generation: generation,
                    runtime: runtime,
                    reportError: reportError
                )
            }
        }
    }

    /// Terminates all managed plugin children during app shutdown.
    func stopAll(runtime: CmuxPluginRuntime) {
        for (pluginID, running) in processes {
            stop(pluginID: pluginID, running: running, runtime: runtime)
        }
        processes.removeAll()
        launchingPluginIDs.removeAll()
        pendingReconciliationPluginIDs.removeAll()
        restartTasks.values.forEach { $0.cancel() }
        restartTasks.removeAll()
        restartAttempts.removeAll()
        restartFingerprints.removeAll()
        CmuxPluginProcessContainment.reapStaleMarkers()
    }

}
