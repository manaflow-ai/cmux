import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    enum RestoreExecution {
        case invocation(AgentRestoreInvocation)
        case legacy(command: String, environment: [String: String])

        var invocation: AgentRestoreInvocation? {
            if case .invocation(let invocation) = self { return invocation }
            return nil
        }
    }

    /// Tells the user, on stderr, how this restore departs from the recorded
    /// launch, right before the agent replaces this process.
    func reportRestoreNotices(_ notices: [AgentRestoreNotice]) {
        for notice in notices {
            let message: String
            switch notice {
            case .routedLauncherUnavailable(let executable):
                message = String(
                    format: String(
                        localized: "cli.restore.notice.routedLauncherUnavailable",
                        defaultValue: "restore: this session was started through the routed launcher '%@', which is not on PATH. Resuming the agent directly instead."
                    ),
                    executable
                )
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    /// Both legacy fallback branches enter the same admission and lease transaction.
    func legacyRestoreExecution(
        record: RestoreRecord,
        processEnvironment: [String: String],
        workingDirectory: String?
    ) throws -> RestoreExecution {
        if AgentRestorePlanner.allowsLegacyFallback(
            kind: record.kind, mode: AgentRestoreRequestMode(rawValue: record.mode)
        ), let command = record.legacyCommand {
            if record.kind != "codex" {
                // A legacy Claude command may coexist with durable Subrouter
                // markers on records written before structured launch capture
                // was available. Never replay the raw `claude --resume` in
                // that case: it silently loses the proxy route. Rebuild the
                // invocation from the trusted marker pair instead.
                if record.kind == "claude",
                   AgentRestoreRequestMode(rawValue: record.mode) == .resumeAgent,
                   let sessionID = record.checkpointID,
                   SubrouterClaudeResumeRouting().provesRoutedLaunch(
                       launcher: record.launchCommand?.launcher,
                       environment: record.environment
                   ) {
                    guard let legacyLaunch = legacyClaudeLaunchCommand(
                        command: command,
                        sessionID: sessionID,
                        workingDirectory: workingDirectory,
                        environment: record.environment
                    ) else {
                        throw loggedRestoreError(
                            stage: "record.routed-legacy",
                            detail: "kind=claude session=\(sessionID)",
                            message: String(
                                localized: "cli.restore.error.incompleteData",
                                defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                            )
                        )
                    }
                    let request = AgentRestoreRequest(
                        mode: .resumeAgent,
                        kind: record.kind,
                        checkpointID: sessionID,
                        source: record.source,
                        workingDirectory: workingDirectory,
                        environment: record.environment,
                        launchCommand: legacyLaunch,
                        preparedArguments: nil,
                        observedPermissionMode: record.permissionMode
                    )
                    let planner = AgentRestorePlanner(
                        executableFileResolver: AgentRestoreExecutableFileResolver()
                    )
                    if let launcher = planner.missingRoutedLauncher(
                        for: request, ambientEnvironment: processEnvironment
                    ) {
                        throw loggedRestoreError(
                            stage: "launcher.missing",
                            detail: launcher,
                            message: String(
                                format: String(
                                    localized: "cli.restore.error.routedLauncherNotFound",
                                    defaultValue: "restore: this session was started with '%1$@ claude proxy', but '%1$@' is not on PATH in this shell. Add it to PATH, then retry."
                                ),
                                launcher
                            )
                        )
                    }
                    if let invocation = planner.invocation(
                        for: request, ambientEnvironment: processEnvironment
                    ) {
                        return .invocation(invocation)
                    }
                    throw loggedRestoreError(
                        stage: "record.routed-legacy",
                        detail: "kind=claude session=\(sessionID)",
                        message: String(
                            localized: "cli.restore.error.incompleteData",
                            defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                        )
                    )
                }
                return .legacy(command: command, environment: processEnvironment.merging(record.environment) { _, saved in saved })
            }
            if let mode = AgentRestoreRequestMode(rawValue: record.mode), mode != .resumeAgent {
                return .legacy(command: command, environment: processEnvironment.merging(record.environment) { _, saved in saved })
            }
            if record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
               let session = record.checkpointID,
               let legacy = CodexLegacyRestoreCommand(command: command, sessionID: session) {
                var environment = record.launchCommand?.environment ?? [:]
                environment.merge(record.environment) { _, saved in saved }
                environment.merge(legacy.environment) { _, inline in inline }
                let request = AgentRestoreRequest(
                    mode: .resumeAgent, kind: record.kind, checkpointID: session, source: record.source,
                    workingDirectory: workingDirectory, environment: environment,
                    launchCommand: AgentLaunchCommand(
                        launcher: "codex", executablePath: legacy.arguments.first, arguments: legacy.arguments,
                        workingDirectory: workingDirectory, environment: environment,
                        verificationHome: record.launchCommand?.verificationHome
                    ),
                    preparedArguments: legacy.arguments, observedPermissionMode: record.permissionMode
                )
                if let invocation = AgentRestorePlanner(executableFileResolver: AgentRestoreExecutableFileResolver())
                    .invocation(for: request, ambientEnvironment: processEnvironment) {
                    return .invocation(invocation)
                }
            }
        }
        throw loggedRestoreError(
            stage: "record.incomplete", detail: "mode=\(record.mode) kind=\(record.kind)",
            message: String(
                localized: "cli.restore.error.incompleteData",
                defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
            )
        )
    }

    /// Rehydrates the argv portion of a legacy command before routing it
    /// through Subrouter. Older records kept only a shell command, so dropping
    /// that command's Claude options would silently change the user's resume
    /// (model, permission mode, directories, and so on).
    private func legacyClaudeLaunchCommand(
        command: String,
        sessionID: String,
        workingDirectory: String?,
        environment: [String: String]
    ) -> AgentLaunchCommand? {
        guard let words = AgentLaunchTemplateRenderer().arguments(
            template: command,
            executable: "claude",
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            sessionDirectory: nil
        ),
        let executableIndex = words.firstIndex(where: {
            URL(fileURLWithPath: $0).lastPathComponent == "claude"
        }),
        let preserved = AgentLaunchSanitizer.preservedArguments(
            kind: "claude",
            args: Array(words.dropFirst(executableIndex + 1))
        ) else {
            return nil
        }
        let executable = words[executableIndex]
        return AgentLaunchCommand(
            launcher: "claude",
            executablePath: executable,
            arguments: [executable] + preserved,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    /// Claims ownership once and keeps the launch lease through either execution route.
    func runAdmittedRestore(
        execution: RestoreExecution,
        record: RestoreRecord,
        recordSessionID: String?,
        payload: [String: Any],
        bindingPayload: [String: Any]?,
        client: SocketClient,
        surfaceID: String,
        workspaceID: String?,
        effectiveWorkingDirectory: String?,
        workingDirectoryBeforeRestore: String
    ) async throws {
        let invocation = execution.invocation
        let workingDirectory = effectiveWorkingDirectory ?? FileManager.default.currentDirectoryPath
        let launchLease = try invocation.flatMap {
            try acquireRestoreLaunchLease(
                record: record, invocation: $0, restorePayload: payload, client: client,
                workingDirectory: workingDirectory
            )
        }
        defer { launchLease?.release() }
        let codexHome = invocation.flatMap { invocation -> String? in
            guard record.kind == "codex",
                  !CodexRestoreAccount().usesRemoteProvider(arguments: invocation.arguments) else { return nil }
            return CodexRestoreAccount().home(
                environment: invocation.environment, workingDirectory: workingDirectory, fallbackHome: NSHomeDirectory()
            )
        }
        let claim = try await requireRestoreLaunchAdmission(
            record: record, recordSessionID: recordSessionID, restorePayload: payload,
            client: client, effectiveCodexHome: codexHome
        )
        do {
            for preflight in invocation?.preflightInvocations ?? [] {
                try runRestorePreflight(preflight, appliedWorkingDirectory: effectiveWorkingDirectory)
            }
            if codexRestoreBindingRequiresClaim(record),
               !claimCodexRestoreBinding(
                   record: record, bindingPayload: bindingPayload,
                   surfaceID: surfaceID, client: client
               ) {
                releaseRestoreLaunchAdmission(claim, client: client)
                try handleRejectedCodexRestore(
                    .bindingChanged, record: record, bindingPayload: bindingPayload,
                    surfaceID: surfaceID,
                    workspaceID: workspaceID,
                    client: client, workingDirectoryBeforeRestore: workingDirectoryBeforeRestore
                )
                return
            }
            if let launchLease { try transferRestoreLaunchLease(launchLease) }
            switch execution {
            case .invocation(let invocation):
                client.close()
                reportRestoreNotices(invocation.notices)
                try execRestoreInvocation(invocation, appliedWorkingDirectory: effectiveWorkingDirectory, admittedScope: claim)
            case .legacy(let command, let environment):
                try execLegacyRestoreRecord(command, record: record, environment: environment, client: client)
            }
        } catch {
            releaseRestoreLaunchAdmission(claim, client: client)
            throw error
        }
    }
}
