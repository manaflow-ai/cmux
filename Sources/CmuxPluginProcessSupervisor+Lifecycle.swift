import CmuxExtensionKit
import Darwin
import Foundation

extension CmuxPluginProcessSupervisor {

    func snapshotIntegrityDidChange(
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

    func processDidTerminate(
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

    func stop(
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
    func terminateProcess(
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
    func scheduleRestart(
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

    nonisolated static func inheritedPluginEnvironment(
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

    /// Returns whether a pathname is stable against same-user replacement.
    ///
    /// The plugin process runs as the signed-in user, so user-owned or
    /// group/other-writable interpreter files cannot be trusted across the
    /// final path lookup. Every ancestor is checked as well; otherwise a
    /// writable parent directory could swap a root-owned leaf between the
    /// verifier and `execv`.
    static func isTrustedInterpreter(at url: URL) -> Bool {
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL
        while true {
            var metadata = Darwin.stat()
            let result: Int32 = candidate.path.withCString { pointer in
                stat(pointer, &metadata)
            }
            guard result == 0,
                  metadata.st_uid == 0,
                  (metadata.st_mode & mode_t(0o022)) == 0 else {
                return false
            }
            guard candidate.path != "/" else { return true }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return false }
            candidate = parent
        }
    }

    static func launchArguments(
        for execution: CmuxPluginEntrypointExecution,
        entrypointPath: String,
        interpreterPath: String?,
        interpreterSnapshotPath: String?,
        containmentMarkerPath: String
    ) -> [String]? {
        switch execution {
        case .executable:
            return [
                "executable",
                containmentMarkerPath,
                entrypointPath,
            ]
        case .interpreter(let interpreterArguments):
            guard let interpreterPath, let interpreterSnapshotPath else { return nil }
            return [
                "interpreter",
                containmentMarkerPath,
                entrypointPath,
                interpreterPath,
                interpreterSnapshotPath,
            ] + interpreterArguments
        }
    }
}
