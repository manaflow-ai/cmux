import Foundation

@MainActor
final class CodexAppServerSession {
    typealias DataWriter = (Data) async throws -> Void
    typealias OutputSink = (_ stream: String, _ text: String) -> Void
    typealias ActivitySink = (_ activity: [String: Any]) -> Void
    typealias TurnCompleteSink = () -> Void
    typealias FailureSink = (_ details: String?) -> Void

    private static let maxQueuedInputCount = 1
    private static let maxQueuedInputBytes = 64 * 1024

    private let workingDirectory: String?
    private let writeData: DataWriter
    private let outputSink: OutputSink
    private let activitySink: ActivitySink
    private let turnCompleteSink: TurnCompleteSink
    private let failureSink: FailureSink
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var didInitialize = false
    private var threadStartRequestID: Int?
    private var threadID: String?
    private var queuedInputs: [CodexAppServerQueuedInput] = []
    private var stdoutBuffer = ""
    private var didFailStartup = false
    private var activePermissionMode: AgentSessionPermissionMode = .standard
    private var isTurnInFlight = false
    private var turnStartRequestIDs: Set<Int> = []
    private let activityFormatter = CodexAppServerActivityFormatter()

    init(
        workingDirectory: String?,
        writeData: @escaping DataWriter,
        outputSink: @escaping OutputSink,
        activitySink: @escaping ActivitySink = { _ in },
        turnCompleteSink: @escaping TurnCompleteSink = {},
        failureSink: @escaping FailureSink = { _ in }
    ) {
        self.workingDirectory = workingDirectory
        self.writeData = writeData
        self.outputSink = outputSink
        self.activitySink = activitySink
        self.turnCompleteSink = turnCompleteSink
        self.failureSink = failureSink
    }

    func start() async throws {
        initializeRequestID = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "cmux",
                    "title": "cmux",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false
                ]
            ]
        )
    }

    func submit(_ text: String, permissionMode: AgentSessionPermissionMode = .standard) async throws {
        guard !text.isEmpty else { return }
        guard !didFailStartup else {
            throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
        }
        guard !isTurnInFlight else {
            throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
        }
        guard let threadID else {
            guard canQueueInput(text) else {
                throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
            }
            try await withCheckedThrowingContinuation { continuation in
                queuedInputs.append(CodexAppServerQueuedInput(
                    text: text,
                    permissionMode: permissionMode,
                    continuation: continuation
                ))
                if didInitialize {
                    Task { @MainActor in
                        do {
                            try await startThreadIfNeeded()
                        } catch {
                            failQueuedInputs(error)
                        }
                    }
                }
            }
            return
        }
        try await sendTurnStart(threadID: threadID, text: text, permissionMode: permissionMode)
    }

    private func canQueueInput(_ text: String) -> Bool {
        guard queuedInputs.count < Self.maxQueuedInputCount else { return false }
        let queuedBytes = queuedInputs.reduce(0) { total, input in
            total + input.text.utf8.count
        }
        return queuedBytes + text.utf8.count <= Self.maxQueuedInputBytes
    }

    func consumeStdout(_ text: String) {
        stdoutBuffer.append(text)
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(...newlineRange.lowerBound)
            if !line.isEmpty {
                handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            outputSink("stderr", String(localized: "agentSession.codex.error.invalidJSON", defaultValue: "Codex app-server response was not valid JSON."))
            return
        }

        if let method = object["method"] as? String,
           object["id"] != nil {
            handleServerRequest(object, method: method)
            return
        }

        if let method = object["method"] as? String {
            handleNotification(method: method, params: object["params"] as? [String: Any])
            return
        }

        guard let id = requestID(from: object["id"]) else { return }
        if let error = object["error"] as? [String: Any] {
            handleRPCError(id: id, error: error)
            return
        }
        handleResponse(id: id, result: object["result"] as? [String: Any])
    }

    private func handleResponse(id: Int, result: [String: Any]?) {
        if id == initializeRequestID {
            initializeRequestID = nil
            didInitialize = true
            Task { @MainActor in
                do {
                    try await sendNotification(method: "initialized")
                    try await startThreadIfNeeded()
                } catch {
                    failStartup(details: error.localizedDescription)
                }
            }
            return
        }

        if id == threadStartRequestID {
            guard let thread = result?["thread"] as? [String: Any],
                  let id = thread["id"] as? String else {
                failStartup(details: nil)
                return
            }
            threadID = id
            threadStartRequestID = nil
            drainCodexAppServerQueuedInputs()
            return
        }

        if turnStartRequestIDs.remove(id) != nil {
            return
        }
    }

    private func handleRPCError(id: Int, error: [String: Any]) {
        let details = error["message"] as? String
        if id == initializeRequestID || id == threadStartRequestID {
            failStartup(details: details)
            return
        }
        if turnStartRequestIDs.remove(id) != nil {
            isTurnInFlight = false
            activePermissionMode = .standard
            emitCodexRPCFailure(details: details)
            return
        }
        emitCodexRPCFailure(details: details)
    }

    private func handleNotification(method: String, params: [String: Any]?) {
        switch method {
        case "thread/started":
            if threadID == nil,
               let thread = params?["thread"] as? [String: Any],
               let id = thread["id"] as? String {
                threadID = id
                threadStartRequestID = nil
                drainCodexAppServerQueuedInputs()
            }
        case "item/agentMessage/delta":
            if let delta = params?["delta"] as? String {
                outputSink("stdout", delta)
            }
        case "item/agentMessage/completed", "item/agentMessage/complete", "item/agentMessage/finished":
            completeTurn()
        case "item/started":
            if let item = params?["item"] as? [String: Any] {
                emitActivity(for: item, defaultStatus: "inProgress")
            }
        case "item/completed":
            if let item = params?["item"] as? [String: Any] {
                if activityFormatter.itemIsAgentMessage(item) {
                    completeTurn()
                    return
                }
                emitActivity(for: item, defaultStatus: "completed")
            }
        case "turn/completed", "turn/complete", "turn/finished", "turn/end", "turn/ended",
             "turn/stopped", "turn/failed", "turn/canceled", "turn/cancelled":
            completeTurn()
        case "item/commandExecution/outputDelta":
            guard let itemID = params?["itemId"] as? String else { break }
            emitActivity(
                activityID: itemID,
                kind: "command",
                status: "inProgress",
                action: activityFormatter.commandAction(status: "inProgress"),
                detail: nil,
                outputDelta: params?["delta"] as? String
            )
        case "item/fileChange/patchUpdated":
            guard let itemID = params?["itemId"] as? String else { break }
            let summary = activityFormatter.fileChangeSummary(from: params?["changes"])
            emitActivity(
                activityID: itemID,
                kind: "fileChange",
                status: "inProgress",
                action: activityFormatter.fileChangeAction(changeType: summary.changeType, status: "inProgress"),
                detail: summary.path
            )
        case "error":
            let error = params?["error"] as? [String: Any]
            let details = error?["message"] as? String
            if threadID == nil || initializeRequestID != nil || threadStartRequestID != nil {
                failStartup(details: details)
            } else {
                emitCodexRPCFailure(details: details)
            }
        case "warning", "guardianWarning", "configWarning", "deprecationNotice":
            outputSink("stderr", activityFormatter.codexMessage(from: params) ?? activityFormatter.unknownWarningMessage())
        default:
            break
        }
    }

    private func completeTurn() {
        isTurnInFlight = false
        activePermissionMode = .standard
        turnCompleteSink()
    }

    private func emitActivity(for item: [String: Any], defaultStatus: String) {
        guard let itemID = item["id"] as? String,
              let itemType = item["type"] as? String else {
            return
        }
        let status = activityFormatter.activityStatus(from: item, defaultStatus: defaultStatus)
        switch itemType {
        case "commandExecution":
            emitActivity(
                activityID: itemID,
                kind: "command",
                status: status,
                action: activityFormatter.commandAction(status: status),
                detail: activityFormatter.commandText(from: item)
            )
        case "fileChange":
            let summary = activityFormatter.fileChangeSummary(from: item["changes"])
            emitActivity(
                activityID: itemID,
                kind: "fileChange",
                status: status,
                action: activityFormatter.fileChangeAction(changeType: summary.changeType, status: status),
                detail: summary.path
            )
        default:
            break
        }
    }

    private func emitActivity(
        activityID: String,
        kind: String,
        status: String,
        action: String,
        detail: String?,
        outputDelta: String? = nil
    ) {
        var activity: [String: Any] = [
            "activityId": activityID,
            "kind": kind,
            "status": status,
            "action": action
        ]
        if let detail, !detail.isEmpty {
            activity["detail"] = detail
        }
        if let outputDelta, !outputDelta.isEmpty {
            activity["outputDelta"] = outputDelta
        }
        activitySink(activity)
    }

    private func handleServerRequest(_ object: [String: Any], method: String) {
        guard let id = object["id"] else { return }
        guard let result = activePermissionMode.approvalReply(
            forServerMethod: method,
            params: object["params"] as? [String: Any]
        ) else {
            Task { @MainActor in
                do {
                    try await sendErrorResponse(
                        id: id,
                        code: -32601,
                        message: String(
                            format: String(
                                localized: "agentSession.codex.error.unsupportedServerRequest",
                                defaultValue: "Request from Codex app-server is not supported: %@"
                            ),
                            method
                        )
                    )
                } catch {
                    emitCodexRPCFailure(error)
                }
            }
            return
        }

        Task { @MainActor in
            do {
                try await sendJSONObject(["id": id, "result": result])
            } catch {
                emitCodexRPCFailure(error)
            }
        }
    }

    private func drainCodexAppServerQueuedInputs() {
        guard let threadID else { return }
        let inputs = queuedInputs
        queuedInputs.removeAll()
        for input in inputs {
            Task { @MainActor in
                do {
                    try await sendTurnStart(
                        threadID: threadID,
                        text: input.text,
                        permissionMode: input.permissionMode
                    )
                    input.resume()
                } catch {
                    input.resume(throwing: error)
                    emitCodexRPCFailure(error)
                }
            }
        }
    }

    private func startThreadIfNeeded() async throws {
        guard !didFailStartup else {
            throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
        }
        guard threadID == nil, threadStartRequestID == nil else { return }
        var params: [String: Any] = [
            "serviceName": "cmux",
            "threadSource": "user"
        ]
        if let workingDirectory {
            params["cwd"] = workingDirectory
        }
        threadStartRequestID = try await sendRequest(method: "thread/start", params: params)
    }

    private func failStartup(details: String?) {
        guard !didFailStartup else { return }
        didFailStartup = true
        initializeRequestID = nil
        didInitialize = false
        threadStartRequestID = nil
        threadID = nil
        isTurnInFlight = false
        activePermissionMode = .standard
        turnStartRequestIDs.removeAll()
        failQueuedInputs(AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName))
        emitCodexRPCFailure(details: details)
        failureSink(details)
    }

    private func failQueuedInputs(_ error: Error) {
        let inputs = queuedInputs
        queuedInputs.removeAll()
        for input in inputs {
            input.resume(throwing: error)
        }
    }

    private func sendTurnStart(
        threadID: String,
        text: String,
        permissionMode: AgentSessionPermissionMode
    ) async throws {
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [
                [
                    "type": "text",
                    "text": text,
                    "text_elements": []
                ]
            ]
        ]
        for (key, value) in permissionMode.codexTurnOverrides {
            params[key] = value
        }
        activePermissionMode = permissionMode
        isTurnInFlight = true
        do {
            let requestID = try await sendRequest(
                method: "turn/start",
                params: params
            )
            turnStartRequestIDs.insert(requestID)
        } catch {
            activePermissionMode = .standard
            isTurnInFlight = false
            throw error
        }
    }

    @discardableResult
    private func sendRequest(method: String, params: Any) async throws -> Int {
        let id = nextRequestID
        nextRequestID += 1
        try await sendJSONObject([
            "id": id,
            "method": method,
            "params": params
        ])
        return id
    }

    private func sendNotification(method: String) async throws {
        try await sendJSONObject(["method": method])
    }

    private func sendErrorResponse(id: Any, code: Int, message: String) async throws {
        try await sendJSONObject([
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func sendJSONObject(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try await writeData(data)
    }

    private func requestID(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func emitCodexRPCFailure(_ error: Error) {
#if DEBUG
        cmuxDebugLog("agentSession.codex.rpc.failed error=\(error.localizedDescription)")
#endif
        outputSink("stderr", activityFormatter.rpcFailedMessage())
    }

    private func emitCodexRPCFailure(details: String?) {
#if DEBUG
        if let details, !details.isEmpty {
            cmuxDebugLog("agentSession.codex.rpc.failed details=\(details)")
        }
#else
        _ = details
#endif
        outputSink("stderr", activityFormatter.rpcFailedMessage())
    }
}
