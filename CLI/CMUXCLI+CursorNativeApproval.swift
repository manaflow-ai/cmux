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
        socketPath: String?
    ) {
        guard let socketPath = normalizedHookValue(socketPath),
              let workspaceId = normalizedHookValue(workspaceId),
              UUID(uuidString: workspaceId) != nil,
              let surfaceId = normalizedHookValue(surfaceId),
              UUID(uuidString: surfaceId) != nil,
              let sessionId = Self.nativeAttentionOpaqueIdentifier(sessionId),
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
        guard let expectedToolCallId = Self.nativeAttentionOpaqueIdentifier(
            identifiers.expectedToolCallId
        ) else {
            // Cursor's `preToolUse` contract exposes the stable tool-use id
            // that its native permission log records as `toolCallId`. Never
            // claim the next unrelated decision by timing alone.
            return
        }
        guard let executablePath = Bundle.main.executableURL?.path,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            return
        }
        guard let observerLease = CursorNativeApprovalObserverLease.claim(
            processIdentity: processIdentity,
            observationID: identifiers.observationId
        ) else {
            return
        }
        var childOwnsObserverLease = false
        defer {
            if !childOwnsObserverLease {
                observerLease.release()
            }
        }

        let observationEpoch = DispatchTime.now().uptimeNanoseconds
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
            "--observation-epoch", String(observationEpoch),
        ]
        arguments += observerLease.commandArguments
        arguments += ["--surface-id", surfaceId]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = arguments
        // The observer only needs stable path/keychain context. Do not place
        // the socket password (or the hook's unrelated credentials) in a
        // longer-lived child environment; the child resolves the password
        // through the scoped keychain/0600 password file using --socket.
        let parentEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in [
            "HOME",
            "TMPDIR",
            "PATH",
            "CMUX_TAG",
            "CMUX_BUNDLE_ID",
            "CMUX_CLI_SENTRY_DISABLED",
        ] {
            if let value = parentEnvironment[key] {
                environment[key] = value
            }
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let childPID = process.processIdentifier
            guard let childProcessIdentity = AgentPIDProcessIdentity(
                agentTurnPID: Int(childPID)
            ) else {
                _ = Darwin.kill(childPID, SIGTERM)
                return
            }
            guard observerLease.activate(
                childProcessIdentity: childProcessIdentity
            ) else {
                if AgentPIDProcessIdentity(
                    agentTurnPID: Int(childPID)
                ) == childProcessIdentity {
                    _ = Darwin.kill(childPID, SIGTERM)
                }
                return
            }
            childOwnsObserverLease = true
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

        let boundaryEpoch = DispatchTime.now().uptimeNanoseconds
        CursorNativeApprovalObserverLease.cancelAll(
            processIdentity: processIdentity
        )
        let params: [String: Any] = [
            "source": BuiltInAgentIntegration.cursor.feedSourceName,
            "session_id": sessionId,
            "pid": processIdentity.pid,
            "pid_start_seconds": processIdentity.startSeconds,
            "pid_start_microseconds": processIdentity.startMicroseconds,
            "boundary_epoch": String(boundaryEpoch),
        ]
        try? sendAcknowledgedAgentAttentionV2MessageWithRetry(
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
              let sessionId = Self.nativeAttentionOpaqueIdentifier(sessionId),
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
        guard Self.nativeAttentionOpaqueIdentifier(
            identifiers.expectedToolCallId
        ) != nil else { return }
        CursorNativeApprovalObserverLease.cancel(
            processIdentity: processIdentity,
            observationID: identifiers.observationId
        )
        try? sendAcknowledgedAgentAttentionV2MessageWithRetry(
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

    /// The small set of root fields needed to conclude an oversized Cursor
    /// post-tool hook without retaining its untrusted result body.
    struct CursorNativeApprovalOversizedMetadata: Sendable {
        let sessionId: String
        let toolCallId: String
        let generationId: String?
        let command: String?
    }

    /// Incrementally scans a bounded JSON root object while discarding large
    /// values. Cursor may put `tool_output` before its correlation IDs, so a
    /// fixed prefix is insufficient; this scanner keeps only short requested
    /// scalar fields and never buffers an untrusted result string.
    struct CursorNativeApprovalRootFieldScanner {
        static let maximumScanBytes = 4 * 1024 * 1024

        private enum Phase {
            case seekingRoot
            case expectingKeyOrEnd
            case readingKey
            case expectingColon
            case expectingValue
            case readingValue
            case skippingString
            case skippingComposite
            case skippingScalar
            case afterValue
            case finished
            case invalid
        }

        private enum Field {
            case session
            case toolCall
            case generation
            case command
        }

        private var phase: Phase = .seekingRoot
        private var keyBytes: [UInt8] = []
        private var valueBytes: [UInt8] = []
        private var keyOverflowed = false
        private var valueOverflowed = false
        private var pendingKey: Field?
        private var escaped = false
        private var compositeDepth = 0
        private var compositeInString = false
        private var compositeEscaped = false
        private var sessionId: String?
        private var toolCallId: String?
        private var generationId: String?
        private var command: String?

        /// The metadata is available once both required correlation fields
        /// have been seen at the root level.
        var metadata: CursorNativeApprovalOversizedMetadata? {
            guard let sessionId, let toolCallId else { return nil }
            return CursorNativeApprovalOversizedMetadata(
                sessionId: sessionId,
                toolCallId: toolCallId,
                generationId: generationId,
                command: command
            )
        }

        var hasRequiredIdentifiers: Bool {
            sessionId != nil && toolCallId != nil
        }

        mutating func consume(_ data: Data) {
            guard phase != .finished, phase != .invalid else { return }
            for byte in data {
                consume(byte)
                if phase == .finished || phase == .invalid {
                    return
                }
            }
        }

        private mutating func consume(_ byte: UInt8) {
            switch phase {
            case .seekingRoot:
                guard isWhitespace(byte) else {
                    guard byte == 0x7B else {
                        phase = .invalid
                        return
                    }
                    phase = .expectingKeyOrEnd
                    return
                }
            case .expectingKeyOrEnd:
                if isWhitespace(byte) || byte == 0x2C { return }
                if byte == 0x7D {
                    phase = .finished
                } else if byte == 0x22 {
                    keyBytes.removeAll(keepingCapacity: true)
                    keyOverflowed = false
                    escaped = false
                    phase = .readingKey
                } else {
                    phase = .invalid
                }
            case .readingKey:
                guard consumeKeyByte(byte) else { return }
                pendingKey = keyOverflowed
                    ? nil
                    : Self.field(for: Self.decodeString(keyBytes))
                phase = .expectingColon
            case .expectingColon:
                if isWhitespace(byte) { return }
                guard byte == 0x3A else {
                    phase = .invalid
                    return
                }
                phase = .expectingValue
            case .expectingValue:
                if isWhitespace(byte) { return }
                if byte == 0x22 {
                    valueBytes.removeAll(keepingCapacity: true)
                    valueOverflowed = false
                    escaped = false
                    phase = pendingKey == nil ? .skippingString : .readingValue
                } else if byte == 0x7B || byte == 0x5B {
                    compositeDepth = 1
                    compositeInString = false
                    compositeEscaped = false
                    phase = .skippingComposite
                } else if byte == 0x2C {
                    phase = .invalid
                } else if byte == 0x7D {
                    phase = .invalid
                } else {
                    phase = .skippingScalar
                }
            case .readingValue:
                guard consumeValueByte(byte) else { return }
                if !valueOverflowed,
                   let value = Self.decodeString(valueBytes),
                   let field = pendingKey {
                    record(value: value, for: field)
                }
                pendingKey = nil
                phase = .afterValue
            case .skippingString:
                if consumeDiscardedStringByte(byte) {
                    pendingKey = nil
                    phase = .afterValue
                }
            case .skippingComposite:
                consumeCompositeByte(byte)
            case .skippingScalar:
                if byte == 0x2C {
                    pendingKey = nil
                    phase = .expectingKeyOrEnd
                } else if byte == 0x7D {
                    phase = .finished
                }
            case .afterValue:
                if isWhitespace(byte) { return }
                if byte == 0x2C {
                    phase = .expectingKeyOrEnd
                } else if byte == 0x7D {
                    phase = .finished
                } else {
                    phase = .invalid
                }
            case .finished, .invalid:
                return
            }
        }

        private mutating func consumeKeyByte(_ byte: UInt8) -> Bool {
            if escaped {
                append(byte, to: &keyBytes, overflowed: &keyOverflowed, maximumBytes: 128)
                escaped = false
                return false
            }
            if byte == 0x5C {
                append(byte, to: &keyBytes, overflowed: &keyOverflowed, maximumBytes: 128)
                escaped = true
                return false
            }
            if byte == 0x22 {
                return true
            }
            append(byte, to: &keyBytes, overflowed: &keyOverflowed, maximumBytes: 128)
            return false
        }

        private mutating func consumeValueByte(_ byte: UInt8) -> Bool {
            if escaped {
                append(
                    byte,
                    to: &valueBytes,
                    overflowed: &valueOverflowed,
                    maximumBytes: 4_096
                )
                escaped = false
                return false
            }
            if byte == 0x5C {
                append(
                    byte,
                    to: &valueBytes,
                    overflowed: &valueOverflowed,
                    maximumBytes: 4_096
                )
                escaped = true
                return false
            }
            if byte == 0x22 { return true }
            append(
                byte,
                to: &valueBytes,
                overflowed: &valueOverflowed,
                maximumBytes: 4_096
            )
            return false
        }

        private mutating func consumeDiscardedStringByte(_ byte: UInt8) -> Bool {
            if escaped {
                escaped = false
                return false
            }
            if byte == 0x5C {
                escaped = true
                return false
            }
            return byte == 0x22
        }

        private mutating func consumeCompositeByte(_ byte: UInt8) {
            if compositeInString {
                if compositeEscaped {
                    compositeEscaped = false
                } else if byte == 0x5C {
                    compositeEscaped = true
                } else if byte == 0x22 {
                    compositeInString = false
                }
                return
            }
            switch byte {
            case 0x22:
                compositeInString = true
            case 0x7B, 0x5B:
                compositeDepth += 1
            case 0x7D, 0x5D:
                compositeDepth -= 1
                if compositeDepth <= 0 {
                    pendingKey = nil
                    phase = .afterValue
                }
            default:
                break
            }
        }

        private mutating func append(
            _ byte: UInt8,
            to buffer: inout [UInt8],
            overflowed: inout Bool,
            maximumBytes: Int
        ) {
            guard !overflowed else { return }
            guard buffer.count < maximumBytes else {
                overflowed = true
                return
            }
            buffer.append(byte)
        }

        private mutating func record(value: String, for field: Field) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch field {
            case .session where sessionId == nil:
                sessionId = value
            case .toolCall where toolCallId == nil:
                toolCallId = value
            case .generation where generationId == nil:
                generationId = value
            case .command where command == nil:
                command = value
            default:
                break
            }
        }

        private static func field(for key: String?) -> Field? {
            switch key {
            case "session_id", "sessionId", "conversation_id", "conversationId":
                return .session
            case "tool_call_id", "toolCallId", "tool_use_id", "toolUseId", "toolUseID":
                return .toolCall
            case "generation_id", "generationId", "turn_id", "turnId":
                return .generation
            case "command", "shell_command", "shellCommand":
                return .command
            default:
                return nil
            }
        }

        private static func decodeString(_ bytes: [UInt8]) -> String? {
            var wrapped = Data([0x22])
            wrapped.append(contentsOf: bytes)
            wrapped.append(0x22)
            return (try? JSONSerialization.jsonObject(with: wrapped)) as? String
        }

        private func isWhitespace(_ byte: UInt8) -> Bool {
            [0x20, 0x09, 0x0A, 0x0D].contains(byte)
        }
    }

    /// Concludes Cursor attention from the bounded lifecycle projection at
    /// the front of an oversized post-tool payload. The unbounded result body
    /// remains excluded from JSON decoding and Feed transport.
    func concludeCursorNativeApprovalObservation(
        metadata: CursorNativeApprovalOversizedMetadata,
        agentPID: Int,
        socketPath: String?,
        socketPassword: String?
    ) {
        var rawObject: [String: Any] = [
            "session_id": metadata.sessionId,
            "tool_use_id": metadata.toolCallId,
        ]
        if let generationId = metadata.generationId {
            rawObject["generation_id"] = generationId
        }
        if let command = metadata.command {
            rawObject["command"] = command
        }
        concludeCursorNativeApprovalObservation(
            rawObject: rawObject,
            agentPID: agentPID,
            sessionId: metadata.sessionId,
            socketPath: socketPath,
            socketPassword: socketPassword
        )
    }

    func concludeCursorNativeApprovalObservation(
        boundedJSONPrefix: Data,
        agentPID: Int,
        socketPath: String?,
        socketPassword: String?
    ) {
        var scanner = CursorNativeApprovalRootFieldScanner()
        scanner.consume(boundedJSONPrefix)
        guard let metadata = scanner.metadata else { return }
        concludeCursorNativeApprovalObservation(
            metadata: metadata,
            agentPID: agentPID,
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
              ),
              let observationEpochValue = optionValue(
                  commandArgs,
                  name: "--observation-epoch"
              ),
              let observationEpoch = UInt64(observationEpochValue),
              let observerLeaseSlotValue = optionValue(
                  commandArgs,
                  name: "--observer-lease-slot"
              ),
              let observerLeaseSlot = Int(observerLeaseSlotValue),
              let observerLeaseID = optionValue(
                  commandArgs,
                  name: "--observer-lease-id"
              )
        else {
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
        guard let observerLease = CursorNativeApprovalObserverLease.existing(
            processIdentity: processIdentity,
            slotIndex: observerLeaseSlot,
            leaseID: observerLeaseID,
            observationID: observationId
        ), observerLease.isCurrent else {
            return
        }
        defer { observerLease.release() }
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
        // The observer may have been cancelled while it waited for Cursor's
        // log record. Revalidate ownership at the mutation boundary so a late
        // approval cannot resurrect Needs Input for a completed turn.
        guard observerLease.isCurrent else {
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
            "observation_epoch": String(observationEpoch),
        ]
        if let surfaceIdValue = optionValue(commandArgs, name: "--surface-id"),
           let surfaceId = UUID(uuidString: surfaceIdValue) {
            params["surface_id"] = surfaceId.uuidString
        }
        try sendAcknowledgedAgentAttentionV2MessageWithRetry(
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
        let scopeSeed = [
            "source=cursor",
            "pid=\(processIdentity.pid)",
            "start=\(processIdentity.startSeconds).\(processIdentity.startMicroseconds)",
            "session=\(sessionId)",
        ].joined(separator: "\n")
        let scopeId = "cursor-scope-\(digestPrefix(scopeSeed))"
        // Cursor's post-policy payload may normalize or omit command/turn
        // fields. The tool-call id is the contractually stable correlation
        // key, so derive the observation solely from it and the process/session
        // scope captured by the pre-tool event.
        let observationSeed = [
            "scope=\(scopeId)",
            "tool=\(toolCallId ?? "")",
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
