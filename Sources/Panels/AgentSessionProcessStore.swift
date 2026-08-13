import Foundation
import Darwin
import CMUXAgentLaunch

@MainActor
final class AgentSessionProcessStore {
    var eventSink: (([String: Any]) -> Void)?
    var activeProviderSink: ((Bool) -> Void)? {
        didSet {
            emitActiveProviderStateIfNeeded()
        }
    }
    var hasActiveProviderSession: Bool {
        !sessions.isEmpty
    }
    private var sessions: [String: AgentSessionRunningSession] = [:]
    private var lastEmittedHasActiveProviderSession: Bool?
    private static let terminationEscalationInterval: DispatchTimeInterval = .seconds(3)

    func start(
        plan: AgentSessionLaunchPlan,
        workingDirectory: String?,
        workspaceId: UUID? = nil,
        surfaceId: UUID? = nil
    ) async throws -> AgentSessionStartedSession {
        guard sessions.isEmpty else {
            throw AgentSessionBridgeError.sessionAlreadyRunning
        }
        let sessionId = UUID().uuidString
        let process = Process()
        let launchArguments = plan.arguments
        let launchEnvironment = plan.environment(overridingWorkingDirectory: workingDirectory)
        process.executableURL = plan.executableURL
        process.arguments = launchArguments
        process.environment = launchEnvironment
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .standardizedFileURL
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let inputWriter = AgentSessionInputWriter(fileHandle: stdin.fileHandleForWriting)
        let openCodeAuth = OpenCodeServerAuth(environment: launchEnvironment)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let running = AgentSessionRunningSession(
            sessionId: sessionId,
            providerID: plan.provider,
            executablePath: plan.executableURL.path,
            arguments: launchArguments,
            workingDirectory: workingDirectory,
            workspaceId: workspaceId?.uuidString,
            surfaceId: surfaceId?.uuidString,
            process: process,
            stdin: stdin,
            inputWriter: inputWriter,
            openCodeAuthorizationHeader: openCodeAuth?.authorizationHeader
        )
        if plan.provider == .codex {
            let workstreamID = "codex-\(sessionId)"
            running.codexAppServerSession = CodexAppServerSession(
                workingDirectory: workingDirectory,
                writeData: { data in
                    try await inputWriter.write(data)
                },
                outputSink: { [weak self] stream, text in
                    self?.emitOutput(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        stream: stream,
                        text: text
                    )
                },
                activitySink: { [weak self] activity in
                    self?.emitActivity(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        activity: activity
                    )
                },
                turnCompleteSink: { [weak self] in
                    self?.emitTurnComplete(
                        sessionId: sessionId,
                        providerID: plan.provider
                    )
                },
                failureSink: { [weak self] _ in
                    self?.failSession(sessionId: sessionId, status: 1)
                },
                userInputHandler: { [weak self] request in
                    guard let self else {
                        return .error(
                            code: -32001,
                            message: String(
                                localized: "agentSession.codex.error.inputTargetUnavailable",
                                defaultValue: "Codex input target is unavailable."
                            )
                        )
                    }
                    return await self.handleCodexUserInput(
                        request,
                        sessionId: sessionId,
                        workstreamID: workstreamID,
                        workspaceID: workspaceId?.uuidString,
                        surfaceID: surfaceId?.uuidString,
                        processIdentifier: process.processIdentifier
                    )
                },
                userInputResolvedSink: { requestID in
                    FeedCoordinator.shared.invalidateBlockingRequest(
                        requestId: "codex-\(sessionId)-\(requestID)"
                    )
                }
            )
        }
        sessions[sessionId] = running
        if plan.provider == .codex,
           let workspaceId,
           let surfaceId {
            FeedJumpResolver.register(
                agent: "codex",
                sessionId: sessionId,
                target: FeedJumpResolver.Target(
                    workspaceId: workspaceId.uuidString,
                    surfaceId: surfaceId.uuidString
                ),
                textSender: { [weak self] text in
                    guard let self,
                          self.sessions[sessionId]?.providerID == .codex else {
                        return false
                    }
                    do {
                        try await self.writeLine(sessionId: sessionId, text: text)
                        return true
                    } catch {
                        return false
                    }
                }
            )
        }

        running.stdoutReadTask = makeReadTask(stdout.fileHandleForReading, sessionId: sessionId, stream: "stdout")
        running.stderrReadTask = makeReadTask(stderr.fileHandleForReading, sessionId: sessionId, stream: "stderr")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                session.pendingExitStatus = process.terminationStatus
                self.finishSessionIfExitedAndDrained(session)
            }
        }

        do {
            try process.run()
            emitActiveProviderStateIfNeeded()
            try await running.codexAppServerSession?.start()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            running.openCodeEventTask?.cancel()
            sessions.removeValue(forKey: sessionId)
            unregisterFeedTarget(for: running)
            emitActiveProviderStateIfNeeded()
            throw error
        }

        if plan.provider != .opencode {
            emitStarted(session: running)
        }
        return AgentSessionStartedSession(sessionId: sessionId)
    }

    func writeLine(
        sessionId: String,
        permissionMode: AgentSessionPermissionMode = .standard,
        text: String
    ) async throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }

        switch session.providerID {
        case .codex:
            guard let codexAppServerSession = session.codexAppServerSession else {
                throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
            }
            session.didEmitFeedTurnCompletion = false
            try await codexAppServerSession.submit(text, permissionMode: permissionMode)
        case .claude:
            try await writeClaudeStreamJSON(text, to: session.inputWriter)
        case .opencode:
            try await postOpenCodePrompt(text, session: session)
        }
    }

    func stop(sessionId: String) throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        requestTermination(for: session)
    }

    func closeAll() {
        for session in sessions.values {
            requestTermination(for: session)
        }
    }

    private func makeReadTask(_ fileHandle: FileHandle, sessionId: String, stream: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data: Data
                do {
                    data = try fileHandle.read(upToCount: 64 * 1024) ?? Data()
                } catch {
                    data = Data()
                }

                await self?.consumeOutputData(data, sessionId: sessionId, stream: stream)
                if data.isEmpty {
                    return
                }
            }
        }
    }

    private func consumeOutputData(_ data: Data, sessionId: String, stream: String) {
        guard let session = sessions[sessionId] else {
            return
        }
        if data.isEmpty {
            for text in session.flushBufferedOutput(stream: stream) {
                handleOutputLine(text, session: session, stream: stream)
            }
            session.drainedStreams.insert(stream)
            finishSessionIfExitedAndDrained(session)
            return
        }
        for text in session.appendOutputData(data, stream: stream) {
            handleOutputLine(text, session: session, stream: stream)
        }
    }

    private func handleCodexUserInput(
        _ request: CodexAppServerUserInputRequest,
        sessionId: String,
        workstreamID: String,
        workspaceID: String?,
        surfaceID: String?,
        processIdentifier: Int32
    ) async -> CodexAppServerUserInputResolution {
        guard let params = Self.jsonObject(request.paramsJSON) else {
            return .error(
                code: -32602,
                message: String(
                    localized: "agentSession.codex.error.inputParametersMalformed",
                    defaultValue: "Codex input parameters were malformed."
                )
            )
        }
        let isMCPToolApproval = request.method == "mcpServer/elicitation/request"
            && Self.isMCPToolApproval(params)
        if request.method == "mcpServer/elicitation/request",
           !isMCPToolApproval,
           !Self.mcpElicitationIsSupported(params) {
            let event = WorkstreamEvent(
                sessionId: workstreamID,
                hookEventName: .notification,
                rawHookEventName: "mcpServer/elicitation/unsupported",
                source: "codex",
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                toolName: request.method,
                toolInputJSON: request.paramsJSON,
                requestId: nil,
                ppid: processIdentifier > 0 ? Int(processIdentifier) : nil
            )
            Task.detached(priority: .utility) {
                _ = FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 0)
            }
            return Self.mcpResolution(action: "cancel", content: nil)
        }
        let payload = isMCPToolApproval
            ? Self.mcpApprovalFeedPayload(params)
            : Self.codexFeedPayload(method: request.method, params: params)
        guard JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return .error(
                code: -32602,
                message: String(
                    localized: "agentSession.codex.error.inputParametersMalformed",
                    defaultValue: "Codex input parameters were malformed."
                )
            )
        }

        let requestID = "codex-\(sessionId)-\(request.rpcID)"
        let event = WorkstreamEvent(
            sessionId: workstreamID,
            hookEventName: isMCPToolApproval ? .permissionRequest : .notification,
            rawHookEventName: isMCPToolApproval ? nil : request.method,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            toolName: isMCPToolApproval
                ? Self.mcpApprovalDisplayName(params)
                : request.method,
            toolInputJSON: payloadJSON,
            requestId: requestID,
            ppid: processIdentifier > 0 ? Int(processIdentifier) : nil
        )
        let timeout: TimeInterval
        if request.isBlocking {
            // Codex defines blocking input as waiting indefinitely. Keep a
            // distant safety deadline while serverRequest/resolved and process
            // exit provide the normal lifecycle-driven cancellation paths.
            timeout = 7 * 24 * 60 * 60
        } else {
            timeout = min(
                max(Double(request.autoResolutionMilliseconds ?? 120_000) / 1_000, 1),
                120
            )
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            FeedCoordinator.shared.ingestBlockingWithOutcome(
                event: event,
                waitTimeout: timeout
            )
        }.value
        return Self.codexResolution(
            outcome,
            method: request.method,
            params: params
        )
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func mcpElicitationIsSupported(_ params: [String: Any]) -> Bool {
        let mode = (params["mode"] as? String)?.lowercased() ?? "form"
        if mode == "url" {
            guard let rawURL = params["url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        guard mode == "form" || mode == "openai/form" else { return false }
        guard let schema = (params["requestedSchema"] as? [String: Any])
            ?? (params["requested_schema"] as? [String: Any])
            ?? (params["schema"] as? [String: Any]),
            let properties = schema["properties"] as? [String: Any] else {
            return false
        }
        return properties.values.allSatisfy { rawField in
            guard let field = rawField as? [String: Any] else { return false }
            if field["anyOf"] != nil || field["allOf"] != nil {
                return false
            }
            let type = (field["type"] as? String)?.lowercased() ?? "string"
            switch type {
            case "string":
                if let oneOf = field["oneOf"] {
                    return Self.mcpTitledEnumIsSupported(oneOf)
                }
                let format = (field["format"] as? String)?.lowercased()
                guard format == nil || ["date", "date-time", "email", "uri"].contains(format!),
                      Self.mcpNonnegativeInteger(field["minLength"]),
                      Self.mcpNonnegativeInteger(field["maxLength"]),
                      Self.mcpOrderedBounds(field["minLength"], field["maxLength"]),
                      Self.mcpEnumIsSupported(field["enum"]) else { return false }
                if let names = field["enumNames"] {
                    guard let values = field["enum"] as? [Any],
                          let labels = names as? [String],
                          values.count == labels.count else { return false }
                }
                return true
            case "number", "integer":
                return field["oneOf"] == nil
                    && Self.mcpOrderedBounds(field["minimum"], field["maximum"])
                    && Self.mcpEnumIsSupported(field["enum"])
            case "boolean":
                return field["oneOf"] == nil && field["enum"] == nil
            case "array":
                guard field["oneOf"] == nil,
                      Self.mcpNonnegativeInteger(field["minItems"]),
                      Self.mcpNonnegativeInteger(field["maxItems"]),
                      Self.mcpOrderedBounds(field["minItems"], field["maxItems"]),
                      let items = field["items"] as? [String: Any] else { return false }
                if let anyOf = items["anyOf"] {
                    return Self.mcpTitledEnumIsSupported(anyOf)
                }
                return items["enum"] != nil && Self.mcpEnumIsSupported(items["enum"])
            default:
                return false
            }
        }
    }

    static func isMCPToolApproval(_ params: [String: Any]) -> Bool {
        let metadata = (params["_meta"] as? [String: Any])
            ?? (params["meta"] as? [String: Any])
        return (metadata?["codex_approval_kind"] as? String) == "mcp_tool_call"
    }

    private static func mcpApprovalDisplayName(_ params: [String: Any]) -> String {
        let server = (params["serverName"] as? String)
            ?? (params["server_name"] as? String)
            ?? "MCP"
        guard let message = params["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return server
        }
        return "\(server): \(message)"
    }

    private static func mcpApprovalFeedPayload(_ params: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = [
            "app_server_method": "mcpServer/elicitation/request",
            "available_decisions": ["accept", "decline"],
        ]
        if let serverName = params["serverName"] ?? params["server_name"] {
            payload["server_name"] = serverName
        }
        if let message = params["message"] {
            payload["message"] = message
        }
        if let metadata = params["_meta"] ?? params["meta"] {
            payload["metadata"] = metadata
        }
        return payload
    }

    private static func mcpEnumIsSupported(_ raw: Any?) -> Bool {
        guard let raw else { return true }
        guard let values = raw as? [Any] else { return false }
        return values.allSatisfy {
            $0 is String || $0 is NSNumber
        }
    }

    private static func mcpTitledEnumIsSupported(_ raw: Any?) -> Bool {
        guard let values = raw as? [[String: Any]], !values.isEmpty else { return false }
        return values.allSatisfy { option in
            option["const"] is String
                && option["title"] is String
        }
    }

    private static func mcpNonnegativeInteger(_ raw: Any?) -> Bool {
        guard let raw else { return true }
        guard let number = raw as? NSNumber else { return false }
        let value = number.doubleValue
        return value.isFinite && value >= 0 && value.rounded(.towardZero) == value
    }

    private static func mcpOrderedBounds(_ minimum: Any?, _ maximum: Any?) -> Bool {
        let lower = (minimum as? NSNumber)?.doubleValue
        let upper = (maximum as? NSNumber)?.doubleValue
        if minimum != nil, lower == nil { return false }
        if maximum != nil, upper == nil { return false }
        if let lower, !lower.isFinite { return false }
        if let upper, !upper.isFinite { return false }
        guard let lower, let upper else { return true }
        return lower <= upper
    }

    private static func codexFeedPayload(
        method: String,
        params: [String: Any]
    ) -> [String: Any] {
        guard method == "mcpServer/elicitation/request" else { return params }
        var payload = params
        if let requestedSchema = params["requestedSchema"] {
            payload["schema"] = requestedSchema
        } else if let requestedSchema = params["requested_schema"] {
            payload["schema"] = requestedSchema
        }
        if let message = params["message"] as? String {
            payload["prompt"] = message
            payload["title"] = message
        }
        if payload["schema"] == nil,
           payload["fields"] == nil {
            var field: [String: Any] = [
                "id": "continue",
                "prompt": (params["message"] as? String) ?? String(
                    localized: "agentSession.codex.input.continue",
                    defaultValue: "Continue"
                ),
                "input_type": "external",
                "required": false,
            ]
            if let url = params["url"] as? String {
                field["external_url"] = url
            }
            payload["fields"] = [field]
        }
        return payload
    }

    static func codexResolution(
        _ outcome: FeedCoordinator.IngestBlockingOutcome,
        method: String,
        params: [String: Any]
    ) -> CodexAppServerUserInputResolution {
        let isMCP = method == "mcpServer/elicitation/request"
        switch outcome.result {
        case .resolved(_, let decision):
            if isMCP, Self.isMCPToolApproval(params) {
                guard case .permission(let mode) = decision else {
                    return mcpResolution(action: "cancel", content: nil)
                }
                switch mode {
                case .once:
                    return mcpResolution(action: "accept", content: [:])
                case .always:
                    return mcpResolution(
                        action: "accept",
                        content: [:],
                        metadata: ["persist": "session"]
                    )
                case .persistent:
                    return mcpResolution(
                        action: "accept",
                        content: [:],
                        metadata: ["persist": "always"]
                    )
                case .deny:
                    return mcpResolution(action: "decline", content: nil)
                case .all, .bypass:
                    return mcpResolution(action: "cancel", content: nil)
                }
            }
            if isMCP {
                switch decision {
                case .form(let action, let selections):
                    return mcpResolution(
                        action: action.rawValue,
                        content: action == .accept
                            ? mcpContent(selections: selections, params: params)
                            : nil
                    )
                case .question(let selections):
                    return mcpResolution(
                        action: "accept",
                        content: mcpContent(selections: selections, params: params)
                    )
                default:
                    return mcpResolution(action: "cancel", content: nil)
                }
            }
            switch decision {
            case .question(let selections), .form(.accept, let selections):
                return codexAnswersResolution(selections: selections, params: params)
            default:
                return codexAnswersResolution(selections: [], params: params)
            }
        case .timedOut, .notFound, .unavailable, .acknowledged:
            return isMCP
                ? mcpResolution(action: "cancel", content: nil)
                : codexAnswersResolution(selections: [], params: params)
        }
    }

    private static func codexAnswersResolution(
        selections: [String],
        params: [String: Any]
    ) -> CodexAppServerUserInputResolution {
        var answers: [String: [String]] = [:]
        for selection in selections {
            guard let separator = selection.firstIndex(of: "=") else { continue }
            let key = String(selection[..<separator])
            var value = String(selection[selection.index(after: separator)...])
            if value.hasPrefix("other:") {
                value = String(value.dropFirst("other:".count))
            }
            value = codexOptionLabel(value, questionID: key, params: params)
            guard !key.isEmpty, !value.isEmpty else { continue }
            answers[key, default: []].append(value)
        }
        let result: [String: Any] = [
            "answers": answers.mapValues { ["answers": $0] }
        ]
        return jsonResolution(result)
    }

    private static func codexOptionLabel(
        _ value: String,
        questionID: String,
        params: [String: Any]
    ) -> String {
        guard let questions = params["questions"] as? [[String: Any]],
              let question = questions.first(where: { $0["id"] as? String == questionID }),
              let options = question["options"] as? [[String: Any]] else {
            return value
        }
        if let option = options.first(where: {
            let id = ($0["id"] as? String) ?? ($0["value"] as? String)
            return id == value
        }),
           let label = (option["label"] as? String) ?? (option["title"] as? String) {
            return label
        }
        let indexValue = value.lowercased().hasPrefix("opt")
            ? String(value.dropFirst(3))
            : value
        if let index = Int(indexValue), options.indices.contains(index),
           let label = (options[index]["label"] as? String)
                ?? (options[index]["title"] as? String) {
            return label
        }
        return value
    }

    private static func mcpContent(
        selections: [String],
        params: [String: Any]
    ) -> [String: Any] {
        let schema = (params["requestedSchema"] as? [String: Any])
            ?? (params["requested_schema"] as? [String: Any])
            ?? (params["schema"] as? [String: Any])
        let properties = schema?["properties"] as? [String: Any]
        var content: [String: Any] = [:]
        let parsedSelections = selections.compactMap { selection -> (String, String)? in
            guard let separator = selection.firstIndex(of: "=") else { return nil }
            let key = String(selection[..<separator])
            var value = String(selection[selection.index(after: separator)...])
            if value.hasPrefix("other:") {
                value = String(value.dropFirst("other:".count))
            }
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return (key, value)
        }
        let grouped = Dictionary(grouping: parsedSelections, by: { $0.0 })
        for (key, selections) in grouped {
            let fieldSchema = properties?[key] as? [String: Any]
            if (fieldSchema?["type"] as? String)?.lowercased() == "array" {
                let itemSchema = fieldSchema?["items"] as? [String: Any]
                content[key] = selections.map {
                    mcpValue($0.1, schema: itemSchema)
                }
            } else if let value = selections.first?.1 {
                content[key] = mcpValue(value, schema: fieldSchema)
            }
        }
        return content
    }

    private static func mcpValue(
        _ value: String,
        schema: [String: Any]?
    ) -> Any {
        let allowedValues: [Any]? = {
            if let values = schema?["enum"] as? [Any] { return values }
            for key in ["oneOf", "anyOf"] {
                if let options = schema?[key] as? [[String: Any]] {
                    return options.compactMap { $0["const"] }
                }
            }
            return nil
        }()
        if let allowedValues {
            let indexValue = value.lowercased().hasPrefix("opt")
                ? String(value.dropFirst(3))
                : value
            if let index = Int(indexValue), allowedValues.indices.contains(index) {
                return allowedValues[index]
            }
            if let matched = allowedValues.first(where: { mcpScalarString($0) == value }) {
                return matched
            }
        }
        return typedMCPValue(value, schema: schema)
    }

    private static func mcpScalarString(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Bool { return value ? "true" : "false" }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func typedMCPValue(
        _ value: String,
        schema: [String: Any]?
    ) -> Any {
        switch (schema?["type"] as? String)?.lowercased() {
        case "boolean":
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on": return true
            case "0", "false", "no", "n", "off": return false
            default: return value
            }
        case "integer":
            return Int(value) ?? value
        case "number":
            return Double(value) ?? value
        default:
            return value
        }
    }

    private static func mcpResolution(
        action: String,
        content: [String: Any]?,
        metadata: [String: Any]? = nil
    ) -> CodexAppServerUserInputResolution {
        let resolvedContent: Any
        if let content {
            resolvedContent = content
        } else {
            resolvedContent = NSNull()
        }
        var result: [String: Any] = ["action": action, "content": resolvedContent]
        if let metadata {
            result["_meta"] = metadata
        }
        return jsonResolution(result)
    }

    private static func jsonResolution(_ result: [String: Any]) -> CodexAppServerUserInputResolution {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return .error(
                code: -32603,
                message: String(
                    localized: "agentSession.codex.error.inputResponseEncoding",
                    defaultValue: "Codex input response could not be encoded."
                )
            )
        }
        return .result(json: json)
    }

    private func finishSessionIfExitedAndDrained(_ session: AgentSessionRunningSession) {
        guard let status = session.pendingExitStatus,
              session.drainedStreams.isSuperset(of: ["stdout", "stderr"]),
              sessions[session.sessionId] === session else {
            return
        }
        sessions.removeValue(forKey: session.sessionId)
        unregisterFeedTarget(for: session)
        cancelSessionTasks(session)
        emitActiveProviderStateIfNeeded()
        emitExit(
            session: session,
            status: status
        )
    }

    private func failSession(sessionId: String, status: Int32) {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            return
        }
        unregisterFeedTarget(for: session)
        emitActiveProviderStateIfNeeded()
        cancelSessionTasks(session)
        requestTermination(for: session)
        emitExit(
            session: session,
            status: status
        )
    }

    private func requestTermination(for session: AgentSessionRunningSession) {
        session.openCodeEventTask?.cancel()
        if session.process.isRunning {
            session.process.terminate()
        }
        installTerminationEscalationTimer(for: session)
    }

    private func unregisterFeedTarget(for session: AgentSessionRunningSession) {
        guard session.providerID == .codex else { return }
        FeedJumpResolver.unregister(agent: "codex", sessionId: session.sessionId)
    }

    private func installTerminationEscalationTimer(for session: AgentSessionRunningSession) {
        guard session.terminationEscalationTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + Self.terminationEscalationInterval,
            repeating: Self.terminationEscalationInterval
        )
        timer.setEventHandler { [weak self, session] in
            Task { @MainActor in
                if session.process.isRunning {
                    _ = kill(session.process.processIdentifier, SIGKILL)
                    return
                }
                guard let self,
                      self.sessions[session.sessionId] === session else {
                    timer.cancel()
                    return
                }
                guard session.pendingExitStatus != nil else {
                    return
                }
                session.drainedStreams.formUnion(["stdout", "stderr"])
                self.finishSessionIfExitedAndDrained(session)
            }
        }
        session.terminationEscalationTimer = timer
        timer.resume()
    }

    private func cancelSessionTasks(_ session: AgentSessionRunningSession) {
        session.terminationEscalationTimer?.cancel()
        session.terminationEscalationTimer = nil
        session.stdoutReadTask?.cancel()
        session.stdoutReadTask = nil
        session.stderrReadTask?.cancel()
        session.stderrReadTask = nil
        Task {
            await session.inputWriter.close()
        }
        session.openCodeEventTask?.cancel()
        session.openCodeEventTask = nil
    }

    private func handleOutputLine(_ text: String, session: AgentSessionRunningSession, stream: String) {
        if session.providerID == .opencode {
            switch Self.openCodeProcessOutputDisposition(text: text, stream: stream) {
            case .serverURL(let baseURL):
                if session.openCodeBaseURL == nil {
                    session.openCodeBaseURL = baseURL
                    createOpenCodeSession(session)
                }
                return
            case .suppress:
                return
            case .emit:
                break
            }
        }

        if stream == "stdout",
           let codexAppServerSession = session.codexAppServerSession {
            codexAppServerSession.consumeStdout(text)
            return
        }

        if stream == "stdout",
           session.providerID == .claude {
            let completesTurn = session.claudeStreamJSONLineCompletesTurn(text)
            for delta in session.consumeClaudeStreamJSONLine(text) {
                emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: stream,
                    text: delta
                )
            }
            if completesTurn {
                emitTurnComplete(
                    sessionId: session.sessionId,
                    providerID: session.providerID
                )
            }
            return
        }

        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: stream,
            text: text
        )
    }

    static func openCodeProcessOutputDisposition(text: String, stream: String) -> OpenCodeProcessOutputDisposition {
        if let baseURL = openCodeServerURL(from: text) {
            return .serverURL(baseURL)
        }
        if stream == "stdout" {
            return .suppress
        }
        return .emit
    }

    private static func openCodeServerURL(from text: String) -> URL? {
        let marker = "opencode server listening on "
        guard let range = text.range(of: marker) else { return nil }
        let rawURL = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let url = rawURL.flatMap(URL.init(string:)),
              agentSessionIsLoopbackURL(url) else {
            return nil
        }
        return url
    }

    private func createOpenCodeSession(_ session: AgentSessionRunningSession) {
        guard !session.isOpenCodeSessionCreateInFlight,
              session.openCodeSessionID == nil,
              let baseURL = session.openCodeBaseURL else {
            return
        }
        session.isOpenCodeSessionCreateInFlight = true
        Task { @MainActor in
            do {
                let response = try await self.postJSON(
                    to: self.openCodeURL(baseURL: baseURL, path: "session", workingDirectory: session.workingDirectory),
                    body: [:],
                    authorizationHeader: session.openCodeAuthorizationHeader
                )
                guard let id = response["id"] as? String, !id.isEmpty else {
                    throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
                }
                guard self.sessions[session.sessionId] === session else { return }
                session.openCodeSessionID = id
                session.isOpenCodeSessionCreateInFlight = false
                self.startOpenCodeEventStream(session)
                self.emitStarted(session: session)
            } catch {
                session.isOpenCodeSessionCreateInFlight = false
                guard let removedSession = self.sessions.removeValue(forKey: session.sessionId),
                      removedSession === session else {
                    return
                }
                self.unregisterFeedTarget(for: session)
                self.emitActiveProviderStateIfNeeded()
                self.cancelSessionTasks(session)
                self.requestTermination(for: session)
                let message = (error as? AgentSessionBridgeError)?.localizedDescription
                    ?? String(
                        localized: "agentSession.opencode.error.sessionCreateFailed",
                        defaultValue: "OpenCode session could not be created."
                    )
                self.emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: "stderr",
                    text: "\(message)\n"
                )
                self.emitExit(
                    session: session,
                    status: 1
                )
            }
        }
    }

    private func postOpenCodePrompt(_ text: String, session: AgentSessionRunningSession) async throws {
        guard let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
        }
        let url = openCodeURL(
            baseURL: baseURL,
            path: "session/\(openCodeSessionID)/prompt_async",
            workingDirectory: session.workingDirectory
        )
        _ = try await postJSON(
            to: url,
            body: [
                "parts": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ],
            authorizationHeader: session.openCodeAuthorizationHeader
        )
    }

    private func startOpenCodeEventStream(_ session: AgentSessionRunningSession) {
        guard session.openCodeEventTask == nil,
              let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            return
        }
        let url = openCodeURL(baseURL: baseURL, path: "event", workingDirectory: session.workingDirectory)
        let authorizationHeader = session.openCodeAuthorizationHeader
        let sessionId = session.sessionId

        session.openCodeEventTask = Task.detached(priority: .utility) { [weak self] in
            await Self.consumeOpenCodeEventStream(
                sessionId: sessionId,
                openCodeSessionID: openCodeSessionID,
                url: url,
                authorizationHeader: authorizationHeader,
                handleEvent: { event in
                    await self?.handleOpenCodeEvent(
                        event,
                        sessionId: sessionId,
                        openCodeSessionID: openCodeSessionID
                    )
                },
                shouldFailOnEOF: {
                    await self?.openCodeEventStreamEOFRequiresFailure(sessionId: sessionId) ?? false
                },
                failStream: {
                    await self?.failOpenCodeEventStream(
                        sessionId: sessionId,
                        openCodeSessionID: openCodeSessionID
                    )
                }
            )
        }
    }

    nonisolated private static func consumeOpenCodeEventStream(
        sessionId: String,
        openCodeSessionID: String,
        url: URL,
        authorizationHeader: String?,
        handleEvent: ([String: Any]) async -> Void,
        shouldFailOnEOF: () async -> Bool,
        failStream: () async -> Void
    ) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.opencode.displayName)
            }

            var parser = OpenCodeEventStreamParser()
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                for event in parser.consumeLine(line) {
                    await handleEvent(event)
                }
            }
            for event in parser.flush() {
                await handleEvent(event)
            }
            guard !Task.isCancelled,
                  await shouldFailOnEOF() else {
                return
            }
            await failStream()
        } catch {
            guard !Task.isCancelled else { return }
#if DEBUG
            cmuxDebugLog("agentSession.opencode.eventStream.failed error=\(error.localizedDescription)")
#endif
            await failStream()
        }
    }

    private func openCodeEventStreamEOFRequiresFailure(sessionId: String) -> Bool {
        Self.openCodeEventStreamEOFRequiresFailure(
            isCancelled: false,
            processIsRunning: sessions[sessionId]?.process.isRunning == true
        )
    }

    static func openCodeEventStreamEOFRequiresFailure(isCancelled: Bool, processIsRunning: Bool) -> Bool {
        !isCancelled && processIsRunning
    }

    private func failOpenCodeEventStream(sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }
        let message = String(
            localized: "agentSession.opencode.error.eventStreamFailed",
            defaultValue: "OpenCode event stream disconnected."
        )
        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: "stderr",
            text: "\(message)\n"
        )
        failSession(sessionId: sessionId, status: 1)
    }

    private func handleOpenCodeEvent(_ event: [String: Any], sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }

        let completesTurn = session.openCodeEventCompletesAssistantTurn(
            event,
            openCodeSessionID: openCodeSessionID
        )
        for output in session.consumeOpenCodeEvent(event, openCodeSessionID: openCodeSessionID) {
            emitOutput(
                sessionId: session.sessionId,
                providerID: session.providerID,
                stream: "stdout",
                text: output
            )
        }
        if completesTurn {
            emitTurnComplete(
                sessionId: session.sessionId,
                providerID: session.providerID
            )
        }
    }

    private func openCodeURL(baseURL: URL, path: String, workingDirectory: String?) -> URL {
        let url = path.split(separator: "/").reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let workingDirectory {
            components?.queryItems = [URLQueryItem(name: "directory", value: workingDirectory)]
        }
        return components?.url ?? url
    }

    private func postJSON(
        to url: URL,
        body: [String: Any],
        authorizationHeader: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw AgentSessionBridgeError.providerNotReady("OpenCode")
        }
        guard !data.isEmpty else { return [:] }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        return decoded as? [String: Any] ?? [:]
    }

    private func writeClaudeStreamJSON(_ text: String, to inputWriter: AgentSessionInputWriter) async throws {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(0x0A)
        try await inputWriter.write(data)
    }

    private func emitStarted(session: AgentSessionRunningSession) {
        ingestCodexFeedEvent(
            session: session,
            hookEventName: .sessionStart,
            toolName: nil,
            toolInput: nil
        )
        eventSink?([
            "type": "provider.started",
            "sessionId": session.sessionId,
            "providerId": session.providerID.rawValue,
            "executablePath": session.executablePath,
            "arguments": session.arguments
        ])
    }

    private func emitOutput(
        sessionId: String,
        providerID: AgentSessionProviderID,
        stream: String,
        text: String
    ) {
        eventSink?([
            "type": "provider.output",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "stream": stream,
            "text": text
        ])
    }

    private func emitActivity(
        sessionId: String,
        providerID: AgentSessionProviderID,
        activity: [String: Any]
    ) {
        if providerID == .codex,
           let session = sessions[sessionId] {
            let status = activity["status"] as? String
            ingestCodexFeedEvent(
                session: session,
                hookEventName: status == "inProgress" ? .preToolUse : .postToolUse,
                toolName: activity["kind"] as? String,
                toolInput: activity,
                isError: status == "failed"
            )
        }
        var event = activity
        event["type"] = "provider.activity"
        event["sessionId"] = sessionId
        event["providerId"] = providerID.rawValue
        eventSink?(event)
    }

    private func emitTurnComplete(
        sessionId: String,
        providerID: AgentSessionProviderID
    ) {
        if let session = sessions[sessionId],
           providerID == .codex,
           !session.didEmitFeedTurnCompletion {
            session.didEmitFeedTurnCompletion = true
            ingestCodexFeedEvent(
                session: session,
                hookEventName: .stop,
                toolName: nil,
                toolInput: ["reason": "turn_complete"]
            )
        }
        eventSink?([
            "type": "provider.turnComplete",
            "sessionId": sessionId,
            "providerId": providerID.rawValue
        ])
    }

    private func emitExit(
        session: AgentSessionRunningSession,
        status: Int32
    ) {
        if session.providerID == .codex {
            ingestCodexFeedEvent(
                session: session,
                hookEventName: .sessionEnd,
                toolName: nil,
                toolInput: nil
            )
        }
        eventSink?([
            "type": "provider.exit",
            "sessionId": session.sessionId,
            "providerId": session.providerID.rawValue,
            "status": status
        ])
    }

    private func ingestCodexFeedEvent(
        session: AgentSessionRunningSession,
        hookEventName: WorkstreamEvent.HookEventName,
        toolName: String?,
        toolInput: [String: Any]?,
        isError: Bool? = nil
    ) {
        guard session.providerID == .codex,
              let workspaceId = session.workspaceId,
              let surfaceId = session.surfaceId else { return }
        let toolInputJSON: String? = toolInput.flatMap {
            guard JSONSerialization.isValidJSONObject($0),
                  let data = try? JSONSerialization.data(withJSONObject: $0, options: [])
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let event = WorkstreamEvent(
            sessionId: "codex-\(session.sessionId)",
            hookEventName: hookEventName,
            source: "codex",
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            toolName: toolName,
            toolInputJSON: toolInputJSON,
            isError: isError,
            ppid: Int(session.process.processIdentifier)
        )
        Task.detached(priority: .utility) {
            _ = FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 0)
        }
    }

    private func emitActiveProviderStateIfNeeded() {
        let hasActiveProviderSession = self.hasActiveProviderSession
        guard lastEmittedHasActiveProviderSession != hasActiveProviderSession else { return }
        lastEmittedHasActiveProviderSession = hasActiveProviderSession
        activeProviderSink?(hasActiveProviderSession)
    }
}
