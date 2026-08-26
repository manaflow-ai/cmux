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

nonisolated private let pluginProcessLogger = Logger(
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
    private let environmentKeys = CmuxPluginEnvironment()
    private let snapshotter: CmuxPluginExecutionSnapshotter

    private struct RunningProcess {
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

    private var processes: [String: RunningProcess] = [:]
    private var launchingPluginIDs: Set<String> = []
    private var pendingReconciliationPluginIDs: Set<String> = []
    private var restartTasks: [String: Task<Void, Never>] = [:]
    private var restartAttempts: [String: Int] = [:]
    private var restartFingerprints: [String: String] = [:]

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

    private func launch(
        descriptor: CmuxPluginDescriptor,
        executionSnapshot: CmuxPluginExecutionSnapshot,
        sessionToken: String,
        socketPath: String,
        generation: UInt64,
        runtime: CmuxPluginRuntime,
        reportError: @escaping @Sendable (String, String?) -> Void
    ) async {
        let pluginID = descriptor.plugin.manifest.id

        guard !Task.isCancelled,
              runtime.processReconciliationIsAllowed(generation: generation) else {
            await snapshotter.remove(executionSnapshot)
            return
        }

        let snapshotVerifiedBeforeLaunch = await snapshotter.verify(executionSnapshot)
        guard snapshotVerifiedBeforeLaunch,
              runtime.processReconciliationIsAllowed(generation: generation) else {
            await snapshotter.remove(executionSnapshot)
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }

        let process = Process()
        let processGeneration = UUID()
        let launchGate = Pipe()
        let containment: CmuxPluginProcessContainment
        do {
            containment = try CmuxPluginProcessContainment()
        } catch {
            await snapshotter.remove(executionSnapshot)
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }
        let integrityMonitor = CmuxPluginSnapshotIntegrityMonitor(
            rootURL: executionSnapshot.directoryURL.deletingLastPathComponent()
        )
        let integrityTask = Task { @MainActor [weak self, weak runtime] in
            for await _ in integrityMonitor.events {
                guard let self, let runtime else { return }
                await self.snapshotIntegrityDidChange(
                    pluginID: pluginID,
                    expectedSnapshot: executionSnapshot,
                    runtime: runtime,
                    reportError: reportError
                )
            }
        }
        let pinnedEntrypoint = FileHandle(
            fileDescriptor: executionSnapshot.entrypointFileDescriptor,
            closeOnDealloc: false
        )
        let pinnedInterpreter = executionSnapshot.interpreterFileDescriptor.map {
            FileHandle(fileDescriptor: $0, closeOnDealloc: false)
        }
        guard let launcherURL = Bundle.main.executableURL else {
            integrityMonitor.cancel()
            integrityTask.cancel()
            containment.cleanup()
            await snapshotter.remove(executionSnapshot)
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }
        process.executableURL = launcherURL
        process.currentDirectoryURL = executionSnapshot.directoryURL
        // The shell blocks on stdin until the parent has registered its PID.
        // It then duplicates the already-open entrypoint descriptor to fd 3
        // and execs that descriptor. This preserves the PID gate while making
        // pathname replacement after validation unable to change the bytes
        // that receive the plugin token.
        process.arguments = ["--cmux-plugin-launcher"]
            + Self.launchArguments(
                for: executionSnapshot.entrypointExecution,
                containmentMarkerPath: containment.markerURL.path
            )
        var environment = Self.inheritedPluginEnvironment(
            from: ProcessInfo.processInfo.environment
        )
        environment[environmentKeys.pluginIDKey] = pluginID
        environment[environmentKeys.pluginTokenKey] = sessionToken
        environment[environmentKeys.pluginSocketPathKey] = socketPath
        environment[environmentKeys.manifestPathKey] = executionSnapshot.manifestURL.path
        environment[environmentKeys.entrypointPathKey] = executionSnapshot.entrypointURL.path
        environment[environmentKeys.apiVersionKey] = "\(descriptor.plugin.manifest.minimumAPIVersion.major).\(descriptor.plugin.manifest.minimumAPIVersion.minor)"
        // Existing cmux SDKs and the bundled CLI both discover the socket via
        // this conventional variable. Keep it alongside the plugin-specific
        // name so a plugin can use any ordinary socket client library.
        environment[environmentKeys.socketPathKey] = socketPath
        process.environment = environment
        process.standardInput = launchGate
        process.standardOutput = pinnedEntrypoint
        process.standardError = pinnedInterpreter ?? FileHandle.nullDevice

        // Install the callback before `run()`: a short-lived plugin can exit
        // between process creation and the first supervisor bookkeeping step.
        process.terminationHandler = { [weak self, weak runtime] terminatedProcess in
            let terminatedID = terminatedProcess.processIdentifier
            let status = terminatedProcess.terminationStatus
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime else { return }
                self.processDidTerminate(
                    pluginID: pluginID,
                    processID: terminatedID,
                    processGeneration: processGeneration,
                    status: status,
                    containment: containment,
                    runtime: runtime,
                    reportError: reportError
                )
            }
        }

        do {
            try process.run()
        } catch {
            try? launchGate.fileHandleForReading.close()
            try? launchGate.fileHandleForWriting.close()
            integrityMonitor.cancel()
            integrityTask.cancel()
            containment.cleanup()
            if process.isRunning {
                process.terminate()
            }
            Task { await snapshotter.remove(executionSnapshot) }
            pluginProcessLogger.error(
                "Plugin \(pluginID, privacy: .public) launch failed: \(String(describing: error), privacy: .private)"
            )
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }

        // Keep the child behind the launch gate until a second integrity check
        // confirms that owner-clearable filesystem flags were not bypassed
        // during process setup.
        let snapshotVerifiedAfterRun = await snapshotter.verify(executionSnapshot)
        guard !Task.isCancelled,
              snapshotVerifiedAfterRun,
              runtime.processReconciliationIsAllowed(generation: generation) else {
            try? launchGate.fileHandleForReading.close()
            try? launchGate.fileHandleForWriting.close()
            integrityMonitor.cancel()
            integrityTask.cancel()
            terminateProcess(
                process,
                processGroupID: process.processIdentifier,
                containment: containment
            )
            containment.cleanupIfUnheld()
            Task { await snapshotter.remove(executionSnapshot) }
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }

        let processID = process.processIdentifier
        guard let authorizationIdentity = runtime.registerProcess(
            processID,
            for: pluginID,
            generation: processGeneration,
            processGroupID: processID,
            containmentMarkerURL: containment.markerURL
        ) else {
            terminateProcess(
                process,
                processGroupID: processID,
                containment: containment
            )
            try? launchGate.fileHandleForReading.close()
            try? launchGate.fileHandleForWriting.close()
            integrityMonitor.cancel()
            integrityTask.cancel()
            containment.cleanupIfUnheld()
            Task { await snapshotter.remove(executionSnapshot) }
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }
        processes[pluginID] = RunningProcess(
            process: process,
            fingerprint: descriptor.plugin.manifestFingerprint,
            sessionToken: sessionToken,
            socketPath: socketPath,
            processID: processID,
            processGroupID: processID,
            authorizationIdentity: authorizationIdentity,
            containment: containment,
            snapshot: executionSnapshot,
            integrityMonitor: integrityMonitor,
            integrityTask: integrityTask
        )
        let snapshotVerifiedBeforeGate = await snapshotter.verify(executionSnapshot)
        guard !Task.isCancelled,
              snapshotVerifiedBeforeGate,
              runtime.processReconciliationIsAllowed(generation: generation) else {
            processes.removeValue(forKey: pluginID)
            runtime.revokeProcess(processID, identity: authorizationIdentity)
            try? launchGate.fileHandleForReading.close()
            try? launchGate.fileHandleForWriting.close()
            integrityMonitor.cancel()
            integrityTask.cancel()
            terminateProcess(
                process,
                processGroupID: process.processIdentifier,
                identity: authorizationIdentity,
                containment: containment
            )
            containment.cleanupIfUnheld()
            Task { await snapshotter.remove(executionSnapshot) }
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }
        try? launchGate.fileHandleForReading.close()
        do {
            try launchGate.fileHandleForWriting.write(contentsOf: Data("cmux-ready\n".utf8))
            try launchGate.fileHandleForWriting.close()
        } catch {
            try? launchGate.fileHandleForWriting.close()
            processes.removeValue(forKey: pluginID)
            runtime.revokeProcess(processID, identity: authorizationIdentity)
            integrityMonitor.cancel()
            integrityTask.cancel()
            Task { await snapshotter.remove(executionSnapshot) }
            terminateProcess(
                process,
                processGroupID: process.processIdentifier,
                identity: authorizationIdentity,
                containment: containment
            )
            containment.cleanupIfUnheld()
            pluginProcessLogger.error(
                "Plugin \(pluginID, privacy: .public) launch gate failed: \(String(describing: error), privacy: .private)"
            )
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.launch",
                    defaultValue: "The plugin could not be launched."
                )
            )
            return
        }
        reportError(pluginID, nil)
        // `Process` may exit before the termination callback reaches the main
        // actor. Reconcile that edge immediately so a dead child is never
        // retained as an apparently running plugin.
        if !process.isRunning {
            processDidTerminate(
                pluginID: pluginID,
                processID: processID,
                processGeneration: processGeneration,
                status: process.terminationStatus,
                containment: containment,
                runtime: runtime,
                reportError: reportError
            )
            return
        }
        pluginProcessLogger.debug(
            "Started plugin \(pluginID, privacy: .public) with pid \(processID)"
        )
    }

    private func snapshotIntegrityDidChange(
        pluginID: String,
        expectedSnapshot: CmuxPluginExecutionSnapshot,
        runtime: CmuxPluginRuntime,
        reportError: @escaping @Sendable (String, String?) -> Void
    ) async {
        guard let observed = processes[pluginID],
              observed.snapshot.directoryURL == expectedSnapshot.directoryURL,
              observed.snapshot.fingerprint == expectedSnapshot.fingerprint else {
            return
        }
        guard !(await snapshotter.verify(expectedSnapshot)) else {
            // Metadata-only notifications (for example, an access-time update)
            // are harmless when the approved bytes and inode identities remain.
            return
        }
        guard let running = processes[pluginID],
              running.snapshot.directoryURL == expectedSnapshot.directoryURL,
              running.snapshot.fingerprint == expectedSnapshot.fingerprint else {
            return
        }
        processes.removeValue(forKey: pluginID)
        running.integrityMonitor.cancel()
        running.integrityTask.cancel()
        runtime.revokeProcess(
            running.processID,
            identity: running.authorizationIdentity
        )
        terminateProcess(
            running.process,
            processGroupID: running.processGroupID,
            identity: running.authorizationIdentity,
            containment: running.containment
        )
        Task { await snapshotter.remove(running.snapshot) }
        reportError(
            pluginID,
            String(
                localized: "settings.plugins.error.launch",
                defaultValue: "The plugin could not be launched."
            )
        )
        pluginProcessLogger.error(
            "Plugin \(pluginID, privacy: .public) snapshot changed while running"
        )
    }

    private func processDidTerminate(
        pluginID: String,
        processID: pid_t,
        processGeneration: UUID,
        status: Int32,
        containment: CmuxPluginProcessContainment,
        runtime: CmuxPluginRuntime,
        reportError: @escaping @Sendable (String, String?) -> Void
    ) {
        guard let running = processes[pluginID],
              running.processID == processID,
              running.authorizationIdentity.generation == processGeneration else {
            runtime.processDidExit(
                processID,
                generation: processGeneration,
                containmentMarkerURL: containment.markerURL
            )
            containment.cleanupIfUnheld()
            return
        }
        processes.removeValue(forKey: pluginID)
        runtime.revokeProcess(
            processID,
            identity: running.authorizationIdentity
        )
        terminateProcess(
            running.process,
            processGroupID: running.processGroupID,
            identity: running.authorizationIdentity,
            containment: running.containment
        )
        runtime.processDidExit(
            processID,
            generation: processGeneration,
            containmentMarkerURL: running.containment.markerURL
        )
        running.containment.cleanupIfUnheld()
        running.integrityMonitor.cancel()
        running.integrityTask.cancel()
        Task { await snapshotter.remove(running.snapshot) }
        if status == 0 {
            reportError(
                pluginID,
                String(
                    localized: "settings.plugins.error.exited",
                    defaultValue: "The plugin exited unexpectedly."
                )
            )
            pluginProcessLogger.error("Plugin \(pluginID, privacy: .public) exited unexpectedly")
        } else {
            let format = String(
                localized: "settings.plugins.error.exit",
                defaultValue: "The plugin exited with status %d."
            )
            reportError(pluginID, String.localizedStringWithFormat(format, status))
            pluginProcessLogger.error(
                "Plugin \(pluginID, privacy: .public) exited with status \(status)"
            )
        }
        scheduleRestart(
            pluginID: pluginID,
            fingerprint: running.fingerprint,
            runtime: runtime
        )
    }

    private func stop(
        pluginID: String,
        running: RunningProcess,
        runtime: CmuxPluginRuntime
    ) {
        // Revoke the old generation before a replacement can subscribe. Its
        // delayed termination callback must never tear down the replacement's
        // streams merely because both generations share a plugin id.
        runtime.revokeProcess(
            running.processID,
            identity: running.authorizationIdentity
        )
        running.integrityMonitor.cancel()
        running.integrityTask.cancel()
        Task { await snapshotter.remove(running.snapshot) }
        terminateProcess(
            running.process,
            processGroupID: running.processGroupID,
            identity: running.authorizationIdentity,
            containment: running.containment
        )
        if !running.process.isRunning {
            runtime.processDidExit(
                running.processID,
                generation: running.authorizationIdentity.generation,
                containmentMarkerURL: running.containment.markerURL
            )
            running.containment.cleanupIfUnheld()
        }
        pluginProcessLogger.debug("Stopped plugin \(pluginID, privacy: .public)")
    }

    /// Revocation is a security boundary: terminate the private process group
    /// and immediately escalate so descendants cannot retain the plugin token.
    private func terminateProcess(
        _ process: Process,
        processGroupID: pid_t,
        identity: CmuxPluginProcessIdentity? = nil,
        containment: CmuxPluginProcessContainment? = nil
    ) {
        guard processGroupID > 1 || containment != nil else { return }
        var rootIdentityIsCurrent = true
        if processGroupID > 1, let expectedStart = identity?.startMicroseconds {
            if let currentStart = CmuxPluginRuntime.processStartMicroseconds(processGroupID) {
                rootIdentityIsCurrent = currentStart == expectedStart
            } else {
                // A private group can outlive its leader. With no verifiable
                // root identity, skip the group signal and let the inherited
                // containment marker target descendants individually.
                rootIdentityIsCurrent = false
            }
        }
        guard process.isRunning || identity != nil || containment != nil else { return }
        containment?.terminate(
            rootProcessID: process.processIdentifier,
            processGroupID: processGroupID,
            expectedRootStartMicroseconds: identity?.startMicroseconds
        )
        if containment == nil, rootIdentityIsCurrent {
            _ = Darwin.kill(-processGroupID, SIGTERM)
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
        if process.isRunning && rootIdentityIsCurrent {
            process.terminate()
        }
    }

    /// Restarts an unexpectedly exited enabled plugin through the same
    /// authoritative registry/reconciliation path after a bounded backoff.
    private func scheduleRestart(
        pluginID: String,
        fingerprint: String,
        runtime: CmuxPluginRuntime
    ) {
        restartTasks.removeValue(forKey: pluginID)?.cancel()
        if restartFingerprints[pluginID] != fingerprint {
            restartAttempts[pluginID] = 0
            restartFingerprints[pluginID] = fingerprint
        }
        let attempt = restartAttempts[pluginID, default: 0]
        guard attempt < 3 else { return }
        restartAttempts[pluginID] = attempt + 1
        let backoffSeconds = 2 << attempt
        restartTasks[pluginID] = Task { @MainActor [weak self, weak runtime] in
            try? await ContinuousClock().sleep(for: .seconds(backoffSeconds))
            guard !Task.isCancelled, let self, let runtime else { return }
            self.restartTasks[pluginID] = nil
            runtime.reload()
        }
    }

    nonisolated private static func inheritedPluginEnvironment(
        from host: [String: String]
    ) -> [String: String] {
        let allowedKeys: Set<String> = [
            "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH",
            "SHELL", "TERM", "TMPDIR", "USER", "__CF_USER_TEXT_ENCODING",
        ]
        var environment = host.filter { key, _ in
            allowedKeys.contains(key) || key.hasPrefix("LC_")
        }
        if environment["PATH"]?.isEmpty != false {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return environment
    }

    private static func launchArguments(
        for execution: CmuxPluginEntrypointExecution,
        containmentMarkerPath: String
    ) -> [String] {
        let gate = "exec 9>>\"$1\" || exit 126; shift; read -r cmuxLaunchGate || true; [ \"$cmuxLaunchGate\" = cmux-ready ] || exit 126; exec 3>&1;"
        switch execution {
        case .executable:
            return [
                "-c",
                "\(gate) exec 1>/dev/null 2>/dev/null; exec /dev/fd/3",
                "cmux-plugin-launch-gate",
                containmentMarkerPath,
            ]
        case .interpreter(let interpreterArguments):
            return [
                "-c",
                "\(gate) exec 4>&2; exec 1>/dev/null 2>/dev/null; exec /dev/fd/4 \"$@\" /dev/fd/3",
                "cmux-plugin-launch-gate",
                containmentMarkerPath,
            ] + interpreterArguments
        }
    }
}
