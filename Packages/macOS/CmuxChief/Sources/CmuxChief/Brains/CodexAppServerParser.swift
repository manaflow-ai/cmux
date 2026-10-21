import Foundation

/// The kind of an approval request `codex app-server` sends; each answers
/// with its own decision values.
enum CodexApprovalKind: Sendable, Equatable {
    /// `item/commandExecution/requestApproval` (`accept` / `decline`).
    case command
    /// `item/fileChange/requestApproval` (`accept` / `decline`).
    case fileChange
    /// The v1 `execCommandApproval` (`approved` / `denied`).
    case legacyCommand
    /// The v1 `applyPatchApproval` (`approved` / `denied`).
    case legacyPatch
}

/// What one `codex app-server` stdout line asks of the driver.
enum CodexOutput: Sendable, Equatable {
    /// A turn event for the owner.
    case event(ChiefTurnEvent)
    /// The answer to the driver's request `id`: its result or error message.
    case response(id: Int, result: ChiefJSON?, error: String?)
    /// The server asks to run a command or change files. `command` is the
    /// shell command, nil for file changes.
    case approval(requestID: ChiefJSON, kind: CodexApprovalKind, command: String?, prompt: String)
    /// A server request the driver does not handle; it answers with an error.
    case unsupportedRequest(requestID: ChiefJSON, method: String)
}

/// Turns `codex app-server` JSON-RPC lines (no `jsonrpc` field, as the
/// app-server and acpmux's bridge write them) into Chief turn events.
///
/// - `item/agentMessage/delta` is live text; `item/completed` of the
///   agent message ends the segment.
/// - `item/started` / `item/completed` of a command, file change or tool
///   call start and finish a work card.
/// - `turn/completed` ends the turn: `failed` fails it, `completed` and
///   `interrupted` finish it.
///
/// Notifications for another thread, or for a turn that was stopped, are
/// dropped.
struct CodexAppServerParser: Sendable {
    /// The thread the conversation runs on.
    var threadID: String?
    /// The running turn's id, once `turn/start` answered or `turn/started` arrived.
    private(set) var turnID: String?
    /// Whether a turn is running.
    private(set) var turnActive = false
    private var stoppedTurns: Set<String> = []
    private var openTextItem: String?
    private var streamedItems: Set<String> = []
    private var startedTools: Set<String> = []
    /// Commands of started `commandExecution` items, for approvals that omit theirs.
    private var itemCommands: [String: String] = [:]
    /// Lifts `cmux-question` / `cmux-result` blocks out of the reply text.
    var blocks = ChiefStructuredBlocks()

    init(threadID: String? = nil) {
        self.threadID = threadID
    }

    /// Starts a turn; its id is learned from `turn/start` or `turn/started`.
    mutating func beginTurn() {
        turnActive = true
        turnID = nil
        openTextItem = nil
        streamedItems = []
        startedTools = []
        blocks.reset()
    }

    /// Records the running turn's id.
    mutating func setTurnID(_ id: String) {
        guard turnActive, !stoppedTurns.contains(id) else { return }
        turnID = id
    }

    /// Marks `turn` stopped; its notifications are dropped.
    mutating func stop(turn: String) {
        stoppedTurns.insert(turn)
        if turnID == turn { turnID = nil }
    }

    /// Ends the running turn early (Stop); its later notifications are dropped.
    mutating func abandonTurn() {
        if let turnID { stoppedTurns.insert(turnID) }
        turnActive = false
        turnID = nil
        blocks.reset()
    }

    /// Reads one stdout line; a line that is not JSON yields nothing.
    mutating func consume(_ line: Data) -> [CodexOutput] {
        guard let json = try? ChiefJSON(parsing: line) else { return [] }
        return consume(json)
    }

    /// Reads one parsed stdout line. Reply text passes through ``blocks``.
    mutating func consume(_ line: ChiefJSON) -> [CodexOutput] {
        blocks.session = threadID
        return consumeLine(line).flatMap { output -> [CodexOutput] in
            guard case .event(let event) = output else { return [output] }
            return blocks.filter(event).map(CodexOutput.event)
        }
    }

    private mutating func consumeLine(_ line: ChiefJSON) -> [CodexOutput] {
        let method = line["method"]?.string
        let id = line["id"]
        if let method, let id, !id.isNull { return serverRequest(method, id: id, params: line["params"] ?? .null) }
        if let method { return notification(method, params: line["params"] ?? .null) }
        guard let number = id?.number else { return [] }
        let error = line["error"].map { $0["message"]?.string ?? $0.compactText }
        return [.response(id: Int(number), result: line["result"], error: error)]
    }

    private func serverRequest(_ method: String, id: ChiefJSON, params: ChiefJSON) -> [CodexOutput] {
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"]?.string ?? params["itemId"]?.string.flatMap { itemCommands[$0] }
            let prompt = command.map { "Run `\(ChiefToolPolicy.truncate(ChiefToolPolicy.unwrapShell($0), to: 300))`?" }
                ?? Self.reasonPrompt(params, fallback: "Allow this command?")
            return [.approval(requestID: id, kind: .command, command: command, prompt: prompt)]
        case "item/fileChange/requestApproval":
            return [.approval(requestID: id, kind: .fileChange, command: nil,
                              prompt: Self.reasonPrompt(params, fallback: "Allow these file changes?"))]
        case "execCommandApproval":
            let command = ChiefToolPolicy.shellJoin((params["command"]?.array ?? []).compactMap(\.string))
            return [.approval(requestID: id, kind: .legacyCommand, command: command,
                              prompt: "Run `\(ChiefToolPolicy.truncate(ChiefToolPolicy.unwrapShell(command), to: 300))`?")]
        case "applyPatchApproval":
            let paths = (params["fileChanges"]?.object ?? [:]).keys.sorted()
            let prompt = paths.isEmpty ? "Allow these file changes?" : "Change \(paths.joined(separator: ", "))?"
            return [.approval(requestID: id, kind: .legacyPatch, command: nil, prompt: ChiefToolPolicy.truncate(prompt, to: 300))]
        default:
            return [.unsupportedRequest(requestID: id, method: method)]
        }
    }

    private mutating func notification(_ method: String, params: ChiefJSON) -> [CodexOutput] {
        if let thread = params["threadId"]?.string, let threadID, thread != threadID { return [] }
        switch method {
        case "turn/started":
            if let id = params["turn"]?["id"]?.string { setTurnID(id) }
            return []
        case "item/agentMessage/delta":
            guard accepts(params["turnId"]?.string), let item = params["itemId"]?.string,
                  let delta = params["delta"]?.string, !delta.isEmpty else { return [] }
            var out = item == openTextItem ? [] : endSegment()
            openTextItem = item
            streamedItems.insert(item)
            out.append(.event(.textDelta(delta)))
            return out
        case "item/started":
            guard accepts(params["turnId"]?.string), let item = params["item"], let id = item["id"]?.string,
                  let tool = Self.toolTitle(item), !startedTools.contains(id) else { return [] }
            startedTools.insert(id)
            if let command = item["command"]?.string { itemCommands[id] = command }
            return endSegment() + [.event(.toolStarted(id: id, title: tool.title, detail: tool.detail))]
        case "item/completed":
            guard accepts(params["turnId"]?.string), let item = params["item"], let id = item["id"]?.string else { return [] }
            return itemCompleted(item, id: id)
        case "turn/completed":
            let turn = params["turn"] ?? .null
            guard turnActive, accepts(turn["id"]?.string) else { return [] }
            var out = endSegment()
            turnActive = false
            turnID = nil
            if turn["status"]?.string == "failed" {
                out.append(.event(.failed(turn["error"]?["message"]?.string ?? "Codex failed.")))
            } else {
                out.append(.event(.finished))
            }
            return out
        default:
            return []
        }
    }

    private mutating func itemCompleted(_ item: ChiefJSON, id: String) -> [CodexOutput] {
        if item["type"]?.string == "agentMessage" {
            if streamedItems.contains(id) { return id == openTextItem ? endSegment() : [] }
            // A message that never streamed deltas arrives whole.
            guard let text = item["text"]?.string, !text.isEmpty else { return [] }
            streamedItems.insert(id)
            return endSegment() + [.event(.textDelta(text)), .event(.textSegmentEnd)]
        }
        guard startedTools.remove(id) != nil else { return [] }
        itemCommands.removeValue(forKey: id)
        let status = item["status"]?.string ?? "completed"
        var ok = status == "completed"
        if let exit = item["exitCode"]?.number, exit != 0 { ok = false }
        return [.event(.toolFinished(id: id, ok: ok, preview: Self.toolPreview(item)))]
    }

    /// Whether a notification of `turn` belongs to the running turn.
    private func accepts(_ turn: String?) -> Bool {
        guard turnActive else { return false }
        guard let turn else { return true }
        if stoppedTurns.contains(turn) { return false }
        return turnID == nil || turnID == turn
    }

    private mutating func endSegment() -> [CodexOutput] {
        guard openTextItem != nil else { return [] }
        openTextItem = nil
        return [.event(.textSegmentEnd)]
    }

    /// The work-card title and detail of a tool-like item, nil for others.
    static func toolTitle(_ item: ChiefJSON) -> (title: String, detail: String?)? {
        switch item["type"]?.string {
        case "commandExecution":
            let command = ChiefToolPolicy.unwrapShell(item["command"]?.string ?? "")
            return (ChiefToolPolicy.truncate(command.replacingOccurrences(of: "\n", with: " "), to: 80), command)
        case "fileChange":
            let paths = (item["changes"]?.array ?? []).compactMap { $0["path"]?.string }
            let title = paths.isEmpty ? "Edit files" : "Edit " + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return (ChiefToolPolicy.truncate(title, to: 80), paths.isEmpty ? nil : paths.joined(separator: "\n"))
        case "mcpToolCall":
            let name = item["tool"]?.string ?? "tool"
            return (ChiefToolPolicy.truncate(name, to: 80), item["arguments"].map { ChiefToolPolicy.truncate($0.compactText, to: 4000) })
        case "dynamicToolCall":
            let name = item["tool"]?.string ?? "tool"
            return (ChiefToolPolicy.truncate(name, to: 80), item["arguments"].map { ChiefToolPolicy.truncate($0.compactText, to: 4000) })
        case "webSearch":
            return (ChiefToolPolicy.truncate("Search the web: " + (item["query"]?.string ?? ""), to: 80), nil)
        default:
            return nil
        }
    }

    private static func toolPreview(_ item: ChiefJSON) -> String? {
        if let output = item["aggregatedOutput"]?.string { return ChiefToolPolicy.preview(output) }
        if let message = item["error"]?["message"]?.string { return ChiefToolPolicy.preview(message) }
        if let content = item["result"]?["content"] { return ChiefToolPolicy.preview(ClaudeStreamParser.text(of: content)) }
        return nil
    }

    private static func reasonPrompt(_ params: ChiefJSON, fallback: String) -> String {
        guard let reason = params["reason"]?.string, !reason.isEmpty else { return fallback }
        return ChiefToolPolicy.truncate("\(fallback) \(reason)", to: 300)
    }

    // MARK: Lines for the app-server's stdin

    /// A request line.
    static func request(id: Int, method: String, params: ChiefJSON) -> ChiefJSON {
        ["id": .number(Double(id)), "method": .string(method), "params": params]
    }

    /// A notification line.
    static func notification(method: String) -> ChiefJSON {
        ["method": .string(method)]
    }

    /// The answer to an approval request.
    static func approvalResponse(requestID: ChiefJSON, kind: CodexApprovalKind, allow: Bool) -> ChiefJSON {
        let decision: ChiefJSON
        switch kind {
        case .command, .fileChange:
            decision = allow ? "accept" : "decline"
        case .legacyCommand, .legacyPatch:
            decision = allow ? "approved" : ["denied": ["rejection": "The user rejected this action."]]
        }
        return ["id": requestID, "result": ["decision": decision]]
    }

    /// The error answer to a server request the driver does not handle.
    static func unsupportedResponse(requestID: ChiefJSON, method: String) -> ChiefJSON {
        ["id": requestID, "error": ["code": -32601, "message": .string("cmux Chief does not support \(method)")]]
    }
}
