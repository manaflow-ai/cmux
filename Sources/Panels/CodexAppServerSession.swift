import Foundation

@MainActor
final class CodexAppServerSession {
    typealias DataWriter = (Data) throws -> Void
    typealias OutputSink = (_ stream: String, _ text: String) -> Void
    typealias ActivitySink = (_ activity: [String: Any]) -> Void
    typealias TurnCompleteSink = () -> Void
    typealias FailureSink = (_ details: String?) -> Void

    private struct QueuedInput {
        let text: String
        let permissionMode: AgentSessionPermissionMode
    }

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
    private var queuedInputs: [QueuedInput] = []
    private var stdoutBuffer = ""
    private var didFailStartup = false

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

    func start() throws {
        initializeRequestID = try sendRequest(
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

    func submit(_ text: String, permissionMode: AgentSessionPermissionMode = .standard) throws {
        guard !text.isEmpty else { return }
        guard !didFailStartup else {
            throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
        }
        guard let threadID else {
            queuedInputs.append(QueuedInput(text: text, permissionMode: permissionMode))
            if didInitialize {
                try startThreadIfNeeded()
            }
            return
        }
        try sendTurnStart(threadID: threadID, text: text, permissionMode: permissionMode)
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
            do {
                try sendNotification(method: "initialized")
                try startThreadIfNeeded()
            } catch {
                failStartup(details: error.localizedDescription)
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
            drainQueuedInputs()
            return
        }
    }

    private func handleRPCError(id: Int, error: [String: Any]) {
        let details = error["message"] as? String
        if id == initializeRequestID || id == threadStartRequestID {
            failStartup(details: details)
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
                drainQueuedInputs()
            }
        case "item/agentMessage/delta":
            if let delta = params?["delta"] as? String {
                outputSink("stdout", delta)
            }
        case "item/agentMessage/completed", "item/agentMessage/complete", "item/agentMessage/finished":
            turnCompleteSink()
        case "item/started":
            if let item = params?["item"] as? [String: Any] {
                emitActivity(for: item, defaultStatus: "inProgress")
            }
        case "item/completed":
            if let item = params?["item"] as? [String: Any] {
                if Self.itemIsAgentMessage(item) {
                    turnCompleteSink()
                    return
                }
                emitActivity(for: item, defaultStatus: "completed")
            }
        case "turn/completed", "turn/complete", "turn/finished", "turn/end", "turn/ended",
             "turn/stopped", "turn/failed", "turn/canceled", "turn/cancelled":
            turnCompleteSink()
        case "item/commandExecution/outputDelta":
            guard let itemID = params?["itemId"] as? String else { break }
            emitActivity(
                activityID: itemID,
                kind: "command",
                status: "inProgress",
                action: Self.commandAction(status: "inProgress"),
                detail: nil,
                outputDelta: params?["delta"] as? String
            )
        case "item/fileChange/patchUpdated":
            guard let itemID = params?["itemId"] as? String else { break }
            let summary = Self.fileChangeSummary(from: params?["changes"])
            emitActivity(
                activityID: itemID,
                kind: "fileChange",
                status: "inProgress",
                action: Self.fileChangeAction(changeType: summary.changeType, status: "inProgress"),
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
            outputSink("stderr", codexMessage(from: params) ?? Self.unknownWarningMessage())
        default:
            break
        }
    }

    private static func itemIsAgentMessage(_ item: [String: Any]) -> Bool {
        guard let itemType = item["type"] as? String else { return false }
        switch itemType {
        case "agentMessage", "assistantMessage", "message":
            return true
        default:
            return false
        }
    }

    private func emitActivity(for item: [String: Any], defaultStatus: String) {
        guard let itemID = item["id"] as? String,
              let itemType = item["type"] as? String else {
            return
        }
        let status = Self.activityStatus(from: item, defaultStatus: defaultStatus)
        switch itemType {
        case "commandExecution":
            emitActivity(
                activityID: itemID,
                kind: "command",
                status: status,
                action: Self.commandAction(status: status),
                detail: Self.commandText(from: item)
            )
        case "fileChange":
            let summary = Self.fileChangeSummary(from: item["changes"])
            emitActivity(
                activityID: itemID,
                kind: "fileChange",
                status: status,
                action: Self.fileChangeAction(changeType: summary.changeType, status: status),
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

    private static func activityStatus(from item: [String: Any], defaultStatus: String) -> String {
        if let parsedCommand = item["parsedCmd"] as? [String: Any],
           let isFinished = parsedCommand["isFinished"] as? Bool,
           !isFinished {
            return "inProgress"
        }
        let rawStatus = (item["executionStatus"] as? String) ?? (item["status"] as? String)
        switch rawStatus?.lowercased() {
        case "interrupted", "canceled", "cancelled", "stopped", "declined", "denied", "rejected":
            return "stopped"
        case "failed", "failure", "error":
            return "failed"
        case "inprogress", "in_progress", "running", "started":
            return "inProgress"
        case "completed", "complete", "succeeded", "success":
            return "completed"
        default:
            return defaultStatus
        }
    }

    private static func commandAction(status: String) -> String {
        switch status {
        case "inProgress":
            return String(localized: "agentSession.codex.activity.command.running", defaultValue: "Running")
        case "stopped":
            return String(localized: "agentSession.codex.activity.command.stopped", defaultValue: "Stopped")
        default:
            return String(localized: "agentSession.codex.activity.command.ran", defaultValue: "Ran")
        }
    }

    private static func commandText(from item: [String: Any]) -> String? {
        if let parsedCommand = item["parsedCmd"] as? [String: Any] {
            for key in ["cmd", "command", "name"] {
                if let value = nonEmptyString(parsedCommand[key]) {
                    return value
                }
            }
        }
        for key in ["command", "cmd", "commandText", "name"] {
            if let value = nonEmptyString(item[key]) {
                return value
            }
        }
        if let command = item["command"] as? [Any] {
            let text = command.compactMap { $0 as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func fileChangeAction(changeType: String?, status: String) -> String {
        switch (changeType, status) {
        case ("add", "inProgress"):
            return String(localized: "agentSession.codex.activity.file.creating", defaultValue: "Creating")
        case ("add", _):
            return String(localized: "agentSession.codex.activity.file.created", defaultValue: "Created")
        case ("delete", "inProgress"):
            return String(localized: "agentSession.codex.activity.file.deleting", defaultValue: "Deleting")
        case ("delete", _):
            return String(localized: "agentSession.codex.activity.file.deleted", defaultValue: "Deleted")
        case (_, "inProgress"):
            return String(localized: "agentSession.codex.activity.file.editing", defaultValue: "Editing")
        case (_, "stopped"):
            return String(localized: "agentSession.codex.activity.command.stopped", defaultValue: "Stopped")
        default:
            return String(localized: "agentSession.codex.activity.file.edited", defaultValue: "Edited")
        }
    }

    private static func fileChangeSummary(from value: Any?) -> (path: String?, changeType: String?) {
        if let changes = value as? [String: Any] {
            for key in changes.keys.sorted() {
                let change = changes[key] as? [String: Any]
                return (key, fileChangeType(from: change))
            }
        }
        if let changes = value as? [[String: Any]],
           let first = changes.first {
            let path = nonEmptyString(first["path"]) ?? nonEmptyString(first["filePath"]) ?? nonEmptyString(first["name"])
            return (path, fileChangeType(from: first))
        }
        return (nil, nil)
    }

    private static func fileChangeType(from change: [String: Any]?) -> String? {
        guard let change else { return nil }
        if let type = nonEmptyString(change["type"]) {
            return type
        }
        if let kind = change["kind"] as? [String: Any] {
            return nonEmptyString(kind["type"])
        }
        return nonEmptyString(change["kind"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        let string: String?
        if let value = value as? String {
            string = value
        } else {
            string = nil
        }
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func handleServerRequest(_ object: [String: Any], method: String) {
        guard let id = object["id"] else { return }
        let result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval":
            result = ["decision": "decline"]
        case "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval":
            result = ["decision": "denied"]
        default:
            do {
                try sendErrorResponse(
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
            return
        }

        do {
            try sendJSONObject(["id": id, "result": result])
        } catch {
            emitCodexRPCFailure(error)
        }
    }

    private func drainQueuedInputs() {
        guard let threadID else { return }
        let inputs = queuedInputs
        queuedInputs.removeAll()
        for input in inputs {
            do {
                try sendTurnStart(
                    threadID: threadID,
                    text: input.text,
                    permissionMode: input.permissionMode
                )
            } catch {
                emitCodexRPCFailure(error)
            }
        }
    }

    private func startThreadIfNeeded() throws {
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
        threadStartRequestID = try sendRequest(method: "thread/start", params: params)
    }

    private func failStartup(details: String?) {
        guard !didFailStartup else { return }
        didFailStartup = true
        initializeRequestID = nil
        didInitialize = false
        threadStartRequestID = nil
        threadID = nil
        queuedInputs.removeAll()
        emitCodexRPCFailure(details: details)
        failureSink(details)
    }

    private func sendTurnStart(
        threadID: String,
        text: String,
        permissionMode: AgentSessionPermissionMode
    ) throws {
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
        _ = try sendRequest(
            method: "turn/start",
            params: params
        )
    }

    @discardableResult
    private func sendRequest(method: String, params: Any) throws -> Int {
        let id = nextRequestID
        nextRequestID += 1
        try sendJSONObject([
            "id": id,
            "method": method,
            "params": params
        ])
        return id
    }

    private func sendNotification(method: String) throws {
        try sendJSONObject(["method": method])
    }

    private func sendErrorResponse(id: Any, code: Int, message: String) throws {
        try sendJSONObject([
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func sendJSONObject(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try writeData(data)
    }

    private func requestID(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func codexMessage(from params: [String: Any]?) -> String? {
        if let message = params?["message"] as? String {
            return message
        }
        if let warning = params?["warning"] as? String {
            return warning
        }
        if let error = params?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    private func emitCodexRPCFailure(_ error: Error) {
#if DEBUG
        cmuxDebugLog("agentSession.codex.rpc.failed error=\(error.localizedDescription)")
#endif
        outputSink("stderr", Self.rpcFailedMessage())
    }

    private func emitCodexRPCFailure(details: String?) {
#if DEBUG
        if let details, !details.isEmpty {
            cmuxDebugLog("agentSession.codex.rpc.failed details=\(details)")
        }
#else
        _ = details
#endif
        outputSink("stderr", Self.rpcFailedMessage())
    }

    private static func rpcFailedMessage() -> String {
        String(localized: "agentSession.codex.error.rpcFailed", defaultValue: "Codex app-server request failed.")
    }

    private static func unknownWarningMessage() -> String {
        String(localized: "agentSession.codex.warning.unknown", defaultValue: "Codex app-server reported a warning.")
    }
}

enum AgentSessionPermissionMode: String {
    case standard = "default"
    case autoReview = "auto-review"
    case fullAccess = "full-access"
    case custom

    var codexTurnOverrides: [String: Any] {
        switch self {
        case .standard, .custom:
            return [
                "approvalPolicy": NSNull(),
                "approvalsReviewer": NSNull(),
                "sandboxPolicy": NSNull()
            ]
        case .autoReview:
            return [
                "approvalPolicy": "on-request",
                "approvalsReviewer": "auto_review",
                "sandboxPolicy": NSNull()
            ]
        case .fullAccess:
            return [
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "sandboxPolicy": ["type": "dangerFullAccess"]
            ]
        }
    }
}
