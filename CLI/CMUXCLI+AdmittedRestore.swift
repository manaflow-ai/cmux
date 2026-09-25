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

    /// Both legacy fallback branches enter the same admission and lease transaction.
    func legacyRestoreExecution(
        record: RestoreRecord,
        processEnvironment: [String: String],
        workingDirectory: String?
    ) throws -> RestoreExecution {
        if let command = record.legacyCommand {
            if record.kind != "codex" {
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
    ) throws {
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
        let claim = try requireRestoreLaunchAdmission(
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
            if let invocation {
                try requireCodexWriterAvailable(
                    record: record,
                    invocation: invocation,
                    workingDirectory: workingDirectory
                )
            }
            if let launchLease { try transferRestoreLaunchLease(launchLease) }
            switch execution {
            case .invocation(let invocation):
                client.close()
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
