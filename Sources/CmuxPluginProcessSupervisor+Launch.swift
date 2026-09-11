import CmuxExtensionKit
import Foundation

extension CmuxPluginProcessSupervisor {

    func launch(
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

        // Darwin has no atomic descriptor-based exec primitive. A shebang
        // interpreter is therefore resolved by pathname at the final launch
        // boundary; only a root-owned, non-writable path can make that lookup
        // stable against another same-user process replacing the interpreter.
        if let interpreterURL = executionSnapshot.interpreterURL,
           !Self.isTrustedInterpreter(at: interpreterURL) {
            pluginProcessLogger.error(
                "Plugin \(pluginID, privacy: .public) uses an untrusted interpreter path"
            )
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
        guard let launchArguments = Self.launchArguments(
            for: executionSnapshot.entrypointExecution,
            entrypointPath: executionSnapshot.entrypointURL.path,
            interpreterPath: executionSnapshot.interpreterURL?.path,
            interpreterSnapshotPath: executionSnapshot.interpreterFileDescriptor.map { _ in
                executionSnapshot.directoryURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".cmux-interpreter/executable", isDirectory: false)
                    .path
            },
            containmentMarkerPath: containment.markerURL.path
        ) else {
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
        let integrityMonitor = CmuxPluginSnapshotIntegrityMonitor(
            rootURL: executionSnapshot.directoryURL.deletingLastPathComponent(),
            additionalURLs: executionSnapshot.interpreterURL.map { [$0] } ?? []
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
        // The launcher blocks on stdin until the parent has registered its PID,
        // then performs one final descriptor/path identity check immediately
        // before exec. The entrypoint descriptor is also retained as fd 1 so
        // script interpreters can consume the pinned bytes through fd 3.
        process.arguments = ["--cmux-plugin-launcher"]
            + launchArguments
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
        if let interpreterDescriptor = executionSnapshot.interpreterFileDescriptor {
            process.standardError = FileHandle(
                fileDescriptor: interpreterDescriptor,
                closeOnDealloc: false
            )
        } else {
            process.standardError = FileHandle.nullDevice
        }

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

}
