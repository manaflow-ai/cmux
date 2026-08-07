import CryptoKit
import Darwin
import Dispatch
import Foundation

extension CMUXCLI {
    /// Starts a detached, bounded observer for Cursor's process-generation log.
    /// Cursor's structured `preToolUse` hook carries
    /// the native tool-call id but still fires before the approval decision;
    /// the observer publishes attention only after the matching post-policy
    /// record appears.
    func startCursorNativeApprovalObservation(
        rawObject: [String: Any],
        agentPID: Int,
        sessionId: String,
        workspaceId: String?,
        surfaceId: String?,
        socketPath: String?,
        socketPassword: String?
    ) {
        guard let socketPath = normalizedHookValue(socketPath),
              let workspaceId = normalizedHookValue(workspaceId),
              UUID(uuidString: workspaceId) != nil,
              let processIdentity = AgentPIDProcessIdentity(
                  agentTurnPID: agentPID
              ),
              processIdentity.liveness == .live else {
            return
        }

        let identifiers = Self.cursorNativeAttentionIdentifiers(
            rawObject: rawObject,
            processIdentity: processIdentity,
            sessionId: sessionId
        )
        guard let expectedToolCallId = identifiers.expectedToolCallId else {
            // Cursor's `preToolUse` contract exposes the stable tool-use id
            // that its native permission log records as `toolCallId`. Never
            // claim the next unrelated decision by timing alone.
            return
        }
        guard let executablePath = Bundle.main.executableURL?.path,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            return
        }

        var arguments = [
            executablePath,
            "--socket", socketPath,
            "hooks", "cursor", "__observe-native-approval",
            "--pid", String(processIdentity.pid),
            "--pid-start-seconds", String(processIdentity.startSeconds),
            "--pid-start-microseconds", String(processIdentity.startMicroseconds),
            "--scope-id", identifiers.scopeId,
            "--observation-id", identifiers.observationId,
            "--workspace-id", workspaceId,
            "--session-id", sessionId,
            "--expected-tool-call-id", expectedToolCallId,
        ]
        if let surfaceId = normalizedHookValue(surfaceId),
           UUID(uuidString: surfaceId) != nil {
            arguments += ["--surface-id", surfaceId]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "CMUX_SOCKET",
            "CMUX_SOCKET_CAPABILITY",
            "CMUX_SOCKET_PATH",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_WORKSPACE_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_PANEL_ID",
            "CMUXD_UNIX_PATH",
            "CMUX_DEBUG_LOG",
        ] {
            environment.removeValue(forKey: key)
        }
        if let socketPassword = normalizedHookValue(socketPassword) {
            environment["CMUX_SOCKET_PASSWORD"] = socketPassword
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            CLISocketSentryTelemetry(
                command: "hooks",
                commandArgs: ["cursor", "__observe-native-approval"],
                socketPath: socketPath,
                processEnv: environment
            ).captureError(
                stage: "cursor_native_approval_observer_spawn",
                error: error
            )
        }
    }

    /// Clears every Cursor observation owned by the exact process generation
    /// when a trustworthy turn/session boundary arrives. Exact tool
    /// conclusions use ``concludeCursorNativeApprovalObservation`` instead.
    func concludeCursorNativeApprovalObservationIfNeeded(
        subcommand: String,
        agentPID: Int?,
        sessionId: String,
        client: SocketClient,
        socketPassword: String?
    ) {
        let clearsProcess = [
            "prompt-submit",
            "stop",
            "agent-response",
            "session-end",
            "session-finalize",
        ].contains(subcommand)
        guard clearsProcess,
              let processIdentity = AgentPIDProcessIdentity(
                  agentTurnPID: agentPID
              ) else {
            return
        }

        let params: [String: Any] = [
            "source": BuiltInAgentIntegration.cursor.feedSourceName,
            "session_id": sessionId,
            "pid": processIdentity.pid,
            "pid_start_seconds": processIdentity.startSeconds,
            "pid_start_microseconds": processIdentity.startMicroseconds,
        ]
        sendBestEffortAgentAttentionV2Message(
            method: "agent.attention.end",
            params: params,
            socketPath: client.socketPath,
            socketPassword: socketPassword
        )
    }

    /// Ends the exact native approval observation paired with Cursor's
    /// structured `preToolUse` event. `postToolUse` and
    /// `postToolUseFailure` carry the same `tool_use_id`, so concurrent shell
    /// calls cannot decrement one another's reconciliation token.
    func concludeCursorNativeApprovalObservation(
        rawObject: [String: Any],
        agentPID: Int,
        sessionId: String,
        socketPath: String?,
        socketPassword: String?
    ) {
        guard let socketPath = normalizedHookValue(socketPath),
              let processIdentity = AgentPIDProcessIdentity(
                  agentTurnPID: agentPID
              )
        else {
            return
        }
        let identifiers = Self.cursorNativeAttentionIdentifiers(
            rawObject: rawObject,
            processIdentity: processIdentity,
            sessionId: sessionId
        )
        guard identifiers.expectedToolCallId != nil else { return }
        sendBestEffortAgentAttentionV2Message(
            method: "agent.attention.end",
            params: [
                "source":
                    BuiltInAgentIntegration.cursor.feedSourceName,
                "session_id": sessionId,
                "observation_id": identifiers.observationId,
                "pid": processIdentity.pid,
                "pid_start_seconds": processIdentity.startSeconds,
                "pid_start_microseconds":
                    processIdentity.startMicroseconds,
            ],
            socketPath: socketPath,
            socketPassword: socketPassword
        )
    }

    /// Hidden detached-child entrypoint. It deliberately opens no cmux socket
    /// until Cursor confirms a native prompt, so auto-approved commands create
    /// neither a long-lived socket connection nor any UI mutation.
    func runCursorNativeApprovalObserver(
        commandArgs: [String],
        socketPath: String,
        socketPassword: String?
    ) throws {
        guard let pidValue = optionValue(commandArgs, name: "--pid"),
              let pid = Int(pidValue),
              pid > 0,
              pid <= Int(Int32.max),
              let startSecondsValue = optionValue(
                  commandArgs,
                  name: "--pid-start-seconds"
              ),
              let startSeconds = Int64(startSecondsValue),
              let startMicrosecondsValue = optionValue(
                  commandArgs,
                  name: "--pid-start-microseconds"
              ),
              let startMicroseconds = Int64(startMicrosecondsValue),
              let scopeId = Self.nativeAttentionOpaqueIdentifier(
                  optionValue(commandArgs, name: "--scope-id")
              ),
              let observationId = Self.nativeAttentionOpaqueIdentifier(
                  optionValue(commandArgs, name: "--observation-id")
              ),
              let expectedToolCallId = Self.nativeAttentionOpaqueIdentifier(
                  optionValue(
                      commandArgs,
                      name: "--expected-tool-call-id"
                  )
              ),
              let workspaceIdValue = optionValue(
                  commandArgs,
                  name: "--workspace-id"
              ),
              let workspaceId = UUID(uuidString: workspaceIdValue),
              let sessionId = Self.nativeAttentionOpaqueIdentifier(
                  optionValue(commandArgs, name: "--session-id")
              ) else {
            throw CLIError(
                message: String(
                    localized: "agent_attention.invalid_observer_arguments",
                    defaultValue: "Invalid native approval observer arguments."
                )
            )
        }

        let processIdentity = AgentPIDProcessIdentity(
            pid: pid_t(pid),
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
        guard processIdentity.liveness == .live else { return }
        let outcome = CursorNativeApprovalFileObserver(
            logDirectory: Self.cursorNativeApprovalLogDirectory(),
            processIdentity: processIdentity,
            expectedToolCallId: expectedToolCallId
        ).waitForDecision()
        guard outcome == .approvalRequested,
              processIdentity.liveness == .live else {
            return
        }

        var params: [String: Any] = [
            "source": BuiltInAgentIntegration.cursor.feedSourceName,
            "observation_id": observationId,
            "scope_id": scopeId,
            "workspace_id": workspaceId.uuidString,
            "session_id": sessionId,
            "pid": processIdentity.pid,
            "pid_start_seconds": processIdentity.startSeconds,
            "pid_start_microseconds": processIdentity.startMicroseconds,
        ]
        if let surfaceIdValue = optionValue(commandArgs, name: "--surface-id"),
           let surfaceId = UUID(uuidString: surfaceIdValue) {
            params["surface_id"] = surfaceId.uuidString
        }
        sendBestEffortAgentAttentionV2Message(
            method: "agent.attention.begin",
            params: params,
            socketPath: socketPath,
            socketPassword: socketPassword
        )
    }

    private static func cursorNativeApprovalLogDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(
                "cursor-agent-logs-\(getuid())",
                isDirectory: true
            )
            .standardizedFileURL
    }

    private static func cursorNativeAttentionIdentifiers(
        rawObject: [String: Any],
        processIdentity: AgentPIDProcessIdentity,
        sessionId: String
    ) -> CursorNativeAttentionIdentifiers {
        let generationId = firstNonEmptyString(
            in: rawObject,
            keys: ["generation_id", "generationId", "turn_id", "turnId"]
        )
        let toolCallId = firstNonEmptyString(
            in: rawObject,
            keys: [
                "tool_call_id",
                "toolCallId",
                "tool_use_id",
                "toolUseId",
                "toolUseID",
            ]
        )
        let command = firstNonEmptyString(
            in: rawObject,
            keys: ["command", "shell_command", "shellCommand"]
        )
        let scopeSeed = [
            "source=cursor",
            "pid=\(processIdentity.pid)",
            "start=\(processIdentity.startSeconds).\(processIdentity.startMicroseconds)",
            "session=\(sessionId)",
            "generation=\(generationId ?? "")",
        ].joined(separator: "\n")
        let scopeId = "cursor-scope-\(digestPrefix(scopeSeed))"
        let observationSeed = [
            "scope=\(scopeId)",
            "tool=\(toolCallId ?? "")",
            "command=\(command ?? "")",
        ].joined(separator: "\n")
        return CursorNativeAttentionIdentifiers(
            scopeId: scopeId,
            observationId:
                "cursor-observation-\(digestPrefix(observationSeed))",
            expectedToolCallId: toolCallId
        )
    }

    private static func firstNonEmptyString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func digestPrefix(_ value: String) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for byte in SHA256.hash(data: Data(value.utf8)).prefix(16) {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

}
