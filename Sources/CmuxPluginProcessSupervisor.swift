import CmuxExtensionKit
import CmuxSettings
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
        let snapshot: CmuxPluginExecutionSnapshot
        let integrityMonitor: CmuxPluginSnapshotIntegrityMonitor
    }

    private var processes: [String: RunningProcess] = [:]

    init(snapshotter: CmuxPluginExecutionSnapshotter? = nil) {
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
            guard processes[pluginID] == nil else { continue }
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

    /// Terminates all managed plugin children during app shutdown.
    func stopAll(runtime: CmuxPluginRuntime) {
        for (pluginID, running) in processes {
            stop(pluginID: pluginID, running: running, runtime: runtime)
        }
        processes.removeAll()
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
        let launchGate = Pipe()
        let integrityMonitor = CmuxPluginSnapshotIntegrityMonitor(
            rootURL: executionSnapshot.directoryURL.deletingLastPathComponent(),
            onViolation: { [weak self, weak runtime] in
                Task { @MainActor [weak self, weak runtime] in
                    guard let self, let runtime else { return }
                    self.snapshotIntegrityDidChange(
                        pluginID: pluginID,
                        runtime: runtime,
                        reportError: reportError
                    )
                }
            }
        )
        let pinnedEntrypoint = FileHandle(
            fileDescriptor: executionSnapshot.entrypointFileDescriptor,
            closeOnDealloc: false
        )
        let pinnedInterpreter = executionSnapshot.interpreterFileDescriptor.map {
            FileHandle(fileDescriptor: $0, closeOnDealloc: false)
        }
        process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
        process.currentDirectoryURL = executionSnapshot.directoryURL
        // The shell blocks on stdin until the parent has registered its PID.
        // It then duplicates the already-open entrypoint descriptor to fd 3
        // and execs that descriptor. This preserves the PID gate while making
        // pathname replacement after validation unable to change the bytes
        // that receive the plugin token.
        process.arguments = Self.launchArguments(for: executionSnapshot.entrypointExecution)
        var environment = Self.inheritedPluginEnvironment(
            from: ProcessInfo.processInfo.environment
        )
        environment[environmentKeys.pluginIDKey] = pluginID
        environment[environmentKeys.pluginTokenKey] = sessionToken
        environment[environmentKeys.pluginSocketPathKey] = socketPath
        environment[environmentKeys.manifestPathKey] = executionSnapshot.manifestURL.path
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
                    status: status,
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
        guard snapshotVerifiedAfterRun,
              runtime.processReconciliationIsAllowed(generation: generation) else {
            try? launchGate.fileHandleForReading.close()
            try? launchGate.fileHandleForWriting.close()
            integrityMonitor.cancel()
            if process.isRunning {
                process.terminate()
            }
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
        processes[pluginID] = RunningProcess(
            process: process,
            fingerprint: descriptor.plugin.manifestFingerprint,
            sessionToken: sessionToken,
            socketPath: socketPath,
            processID: processID,
            snapshot: executionSnapshot,
            integrityMonitor: integrityMonitor
        )
        runtime.registerProcess(processID, for: pluginID)
        let snapshotVerifiedBeforeGate = await snapshotter.verify(executionSnapshot)
        guard snapshotVerifiedBeforeGate,
              runtime.processReconciliationIsAllowed(generation: generation) else {
            processes.removeValue(forKey: pluginID)
            runtime.revokeProcess(processID)
            try? launchGate.fileHandleForReading.close()
            try? launchGate.fileHandleForWriting.close()
            integrityMonitor.cancel()
            if process.isRunning {
                process.terminate()
            }
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
            runtime.revokeProcess(processID)
            integrityMonitor.cancel()
            Task { await snapshotter.remove(executionSnapshot) }
            if process.isRunning {
                process.terminate()
            }
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
                status: process.terminationStatus,
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
        runtime: CmuxPluginRuntime,
        reportError: @escaping @Sendable (String, String?) -> Void
    ) {
        guard let running = processes.removeValue(forKey: pluginID) else { return }
        running.integrityMonitor.cancel()
        runtime.revokeProcess(running.processID)
        if running.process.isRunning {
            running.process.terminate()
        }
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
        status: Int32,
        runtime: CmuxPluginRuntime,
        reportError: @escaping @Sendable (String, String?) -> Void
    ) {
        guard let running = processes[pluginID], running.processID == processID else {
            runtime.processDidExit(processID)
            return
        }
        processes.removeValue(forKey: pluginID)
        runtime.processDidExit(processID)
        running.integrityMonitor.cancel()
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
    }

    private func stop(
        pluginID: String,
        running: RunningProcess,
        runtime: CmuxPluginRuntime
    ) {
        // Revoke the old generation before a replacement can subscribe. Its
        // delayed termination callback must never tear down the replacement's
        // streams merely because both generations share a plugin id.
        runtime.revokeProcess(running.processID)
        running.integrityMonitor.cancel()
        Task { await snapshotter.remove(running.snapshot) }
        if running.process.isRunning {
            running.process.terminate()
        }
        pluginProcessLogger.debug("Stopped plugin \(pluginID, privacy: .public)")
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
        for execution: CmuxPluginEntrypointExecution
    ) -> [String] {
        let gate = "read -r cmuxLaunchGate || true; [ \"$cmuxLaunchGate\" = cmux-ready ] || exit 126; exec 3>&1;"
        switch execution {
        case .executable:
            return [
                "-c",
                "\(gate) exec 1>/dev/null 2>/dev/null; exec /dev/fd/3",
                "cmux-plugin-launch-gate",
            ]
        case .interpreter(let interpreterArguments):
            return [
                "-c",
                "\(gate) exec 4>&2; exec 1>/dev/null 2>/dev/null; exec /dev/fd/4 \"$@\" /dev/fd/3",
                "cmux-plugin-launch-gate",
            ] + interpreterArguments
        }
    }
}
