import CryptoKit
import Darwin
import Dispatch
import Foundation

private struct CursorNativeApprovalLogSnapshot {
    let path: String
    let offset: Int64
}

private struct CursorNativeAttentionIdentifiers {
    let scopeId: String
    let observationId: String
    let expectedToolCallId: String?
}

private enum CursorNativeApprovalObservationOutcome: Equatable {
    case approvalRequested
    case autoApproved
    case unavailable
}

extension CMUXCLI {
    /// Starts a detached, bounded observer at the current end of Cursor's own
    /// process-generation log. Cursor's structured `preToolUse` hook carries
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
              processIdentity.liveness == .live,
              let snapshot = Self.cursorNativeApprovalLogSnapshot(
                  processIdentity: processIdentity
              ) else {
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
            "--log-path", snapshot.path,
            "--offset", String(snapshot.offset),
            "--pid", String(processIdentity.pid),
            "--pid-start-seconds", String(processIdentity.startSeconds),
            "--pid-start-microseconds", String(processIdentity.startMicroseconds),
            "--scope-id", identifiers.scopeId,
            "--observation-id", identifiers.observationId,
            "--workspace-id", workspaceId,
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
        guard let logPath = optionValue(commandArgs, name: "--log-path"),
              let offsetValue = optionValue(commandArgs, name: "--offset"),
              let offset = Int64(offsetValue),
              offset >= 0,
              let pidValue = optionValue(commandArgs, name: "--pid"),
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
              Self.isExpectedCursorLogPath(logPath, pid: pid) else {
            throw CLIError(message: "Invalid Cursor native approval observer arguments")
        }

        let processIdentity = AgentPIDProcessIdentity(
            pid: pid_t(pid),
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
        guard processIdentity.liveness == .live else { return }
        let outcome = CursorNativeApprovalFileObserver(
            logPath: logPath,
            initialOffset: offset,
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

    private static func cursorNativeApprovalLogSnapshot(
        processIdentity: AgentPIDProcessIdentity,
        fileManager: FileManager = .default
    ) -> CursorNativeApprovalLogSnapshot? {
        let directory = cursorNativeApprovalLogDirectory(
            fileManager: fileManager
        )
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let pidMarker = "-\(processIdentity.pid)-"
        let earliestCurrentGeneration =
            TimeInterval(processIdentity.startSeconds) - 2
        let candidate = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "log",
                  url.lastPathComponent.contains(pidMarker),
                  let values = try? url.resourceValues(
                      forKeys: [
                          .contentModificationDateKey,
                          .isRegularFileKey,
                      ]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified.timeIntervalSince1970 >= earliestCurrentGeneration
            else {
                return nil
            }
            return (url, modified)
        }.max { $0.1 < $1.1 }?.0
        guard let candidate else { return nil }

        let descriptor = open(candidate.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else {
            return nil
        }
        return CursorNativeApprovalLogSnapshot(
            path: candidate.path,
            offset: Int64(info.st_size)
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

    private static func isExpectedCursorLogPath(
        _ path: String,
        pid: Int,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent()
            == cursorNativeApprovalLogDirectory(fileManager: fileManager)
            && url.pathExtension == "log"
            && url.lastPathComponent.contains("-\(pid)-")
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
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

/// A hidden detached CLI process owns this bounded kernel event wait, so no
/// app actor or UI thread is blocked while Cursor evaluates its native policy.
private final class CursorNativeApprovalFileObserver {
    private enum ReadResult {
        case waiting
        case decision(CursorNativeApprovalObservationOutcome)
        case unavailable
    }

    private static let maximumObservedBytes = 512 * 1024
    private static let readChunkSize = 16 * 1024
    private static let timeoutSeconds = 8
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    private static let terminalVnodeEvents = UInt32(
        NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
    )

    private let logPath: String
    private var offset: Int64
    private let processIdentity: AgentPIDProcessIdentity
    private let expectedToolCallId: String
    private var pendingBytes = Data()
    private var observedByteCount = 0

    init(
        logPath: String,
        initialOffset: Int64,
        processIdentity: AgentPIDProcessIdentity,
        expectedToolCallId: String
    ) {
        self.logPath = logPath
        offset = initialOffset
        self.processIdentity = processIdentity
        self.expectedToolCallId = expectedToolCallId
    }

    func waitForDecision() -> CursorNativeApprovalObservationOutcome {
        guard processIdentity.liveness == .live else { return .unavailable }
        let descriptor = open(logPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }

        let eventQueue = kqueue()
        guard eventQueue >= 0 else { return .unavailable }
        defer { close(eventQueue) }

        var registration = kevent(
            ident: UInt(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(
                NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB
                    | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
            ),
            data: 0,
            udata: nil
        )
        guard kevent(
            eventQueue,
            &registration,
            1,
            nil,
            0,
            nil
        ) == 0 else {
            return .unavailable
        }

        let timeoutNanoseconds =
            UInt64(Self.timeoutSeconds) * Self.nanosecondsPerSecond
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start.addingReportingOverflow(
            timeoutNanoseconds
        )
        guard !deadline.overflow else { return .unavailable }

        while true {
            guard processIdentity.liveness == .live else {
                return .unavailable
            }
            switch consumeAvailableLines(descriptor: descriptor) {
            case .waiting:
                break
            case let .decision(outcome):
                return outcome
            case .unavailable:
                return .unavailable
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.partialValue else {
                return .unavailable
            }
            let remaining = deadline.partialValue - now
            var timeout = timespec(
                tv_sec: Int(
                    remaining / Self.nanosecondsPerSecond
                ),
                tv_nsec: Int(
                    remaining % Self.nanosecondsPerSecond
                )
            )
            var event = kevent()
            let eventCount = kevent(
                eventQueue,
                nil,
                0,
                &event,
                1,
                &timeout
            )
            if eventCount < 0, errno == EINTR {
                continue
            }
            guard eventCount > 0,
                  event.flags & UInt16(EV_ERROR) == 0,
                  event.fflags & Self.terminalVnodeEvents == 0 else {
                return .unavailable
            }
        }
    }

    private func consumeAvailableLines(descriptor: Int32) -> ReadResult {
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_size >= offset else {
            return .unavailable
        }

        while offset < fileInfo.st_size {
            let remainingBudget =
                Self.maximumObservedBytes - observedByteCount
            guard remainingBudget > 0 else {
                return .unavailable
            }
            let requested = min(
                Self.readChunkSize,
                remainingBudget,
                Int(fileInfo.st_size - offset)
            )
            var bytes = [UInt8](repeating: 0, count: requested)
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(
                    descriptor,
                    buffer.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { return .unavailable }
            guard count > 0 else { break }
            offset += Int64(count)
            observedByteCount += count
            pendingBytes.append(contentsOf: bytes.prefix(count))
            if let outcome = consumeCompleteLines() {
                return .decision(outcome)
            }
        }
        return .waiting
    }

    private func consumeCompleteLines()
        -> CursorNativeApprovalObservationOutcome? {
        while let newline = pendingBytes.firstIndex(of: 0x0A) {
            let lineData = pendingBytes[..<newline]
            pendingBytes.removeSubrange(...newline)
            guard let line = String(data: Data(lineData), encoding: .utf8),
                  let decision = CursorNativeApprovalLogClassifier.classify(
                      line: line,
                      expectedToolCallId: expectedToolCallId
                  ) else {
                continue
            }
            switch decision {
            case .approvalRequested:
                return .approvalRequested
            case .autoApproved:
                return .autoApproved
            }
        }
        // A structured record may contain a shell command larger than one
        // read chunk. Keep its head because the correlation fields occur only
        // once; the total observation budget already bounds this buffer.
        if pendingBytes.count > Self.maximumObservedBytes {
            pendingBytes.removeAll(keepingCapacity: false)
        }
        return nil
    }
}
