import Foundation

/// Folds acpmux event records into an ordered list of ``TranscriptRow``s.
///
/// The reducer is a pure value: feed it records in sequence order with ``apply(_:)``,
/// or older pages with ``prepend(_:)``, and read ``rows``. It filters protocol noise
/// (`out` records, responses, replays, usage updates) and keeps only the records it
/// renders, so a rebuild after prepending history is cheap.
///
/// ```swift
/// var reducer = TranscriptReducer()
/// reducer.apply(attach.events)
/// let rows = reducer.rows
/// ```
public struct TranscriptReducer: Sendable {
    /// Rendered rows, oldest first.
    public private(set) var rows: [TranscriptRow] = []
    /// Prompts queued behind the running turn.
    public private(set) var queue: [AcpmuxQueueEntry] = []
    /// The last session status seen in the log.
    public private(set) var status: String?
    /// The newest applied sequence number, or 0.
    public private(set) var lastSeq = 0
    /// The oldest applied sequence number, or `nil` before any record.
    public private(set) var firstSeq: Int?
    /// Whether a turn is open (started and not yet ended).
    public var isTurnOpen: Bool { turn != nil }

    private var records: [AcpmuxEventRecord] = []
    private var indexByID: [String: Int] = [:]
    private var toolRowByCallID: [String: String] = [:]
    private var turn: TurnState?
    private var pendingLocal: [PendingLocalMessage] = []
    private var lastClosedTurn: (startedSeq: Int?, rowID: String)?
    /// ACP `messageId` of the message each prose or thought row streams, when the agent sends one.
    private var messageIDByRow: [String: String] = [:]

    private struct TurnState {
        var key: Int
        var startAt: Int64?
        var toolCount = 0
        var hasOutput = false
        var sawUserMessage = false
        var startedSeq: Int?
        var streamingRowIDs: [String] = []
    }

    private struct PendingLocalMessage {
        var promptId: String
        var text: String
        var at: Int64
        var failed: Bool
    }

    /// Creates an empty reducer.
    public init() {}

    // MARK: - Input

    /// Applies records newer than ``lastSeq``, in order. Older or duplicate records are ignored.
    public mutating func apply(_ newRecords: [AcpmuxEventRecord]) {
        for record in newRecords.sorted(by: { $0.seq < $1.seq }) where record.seq > lastSeq {
            apply(record)
        }
    }

    /// Applies one record newer than ``lastSeq``.
    public mutating func apply(_ record: AcpmuxEventRecord) {
        guard record.seq > lastSeq else { return }
        lastSeq = record.seq
        if firstSeq == nil { firstSeq = record.seq }
        guard Self.isRenderable(record) else { return }
        records.append(record)
        reduce(record)
    }

    /// Adds older records (sequence numbers below ``firstSeq``) and rebuilds the rows.
    public mutating func prepend(_ olderRecords: [AcpmuxEventRecord]) {
        let floor = firstSeq ?? Int.max
        let older = olderRecords.filter { $0.seq < floor }.sorted { $0.seq < $1.seq }
        guard let oldest = older.first else { return }
        firstSeq = oldest.seq
        records = older.filter(Self.isRenderable) + records
        rebuild()
    }

    /// Shows a local echo for a prompt the daemon has not recorded yet.
    ///
    /// The row is keyed by `promptId`, so the daemon's `user_message` record for the same
    /// prompt replaces it in place.
    public mutating func addPendingUserMessage(promptId: String, text: String, at: Int64) {
        let local = PendingLocalMessage(promptId: promptId, text: text, at: at, failed: false)
        pendingLocal.append(local)
        insertPending(local)
    }

    /// Replaces the queue with the daemon's authoritative list, for example from attach.
    public mutating func replaceQueue(_ entries: [AcpmuxQueueEntry]) {
        queue = entries
    }

    /// Marks a local echo as failed, for example when the daemon rejected the prompt.
    public mutating func markPendingUserMessageFailed(promptId: String) {
        guard let index = pendingLocal.firstIndex(where: { $0.promptId == promptId }) else { return }
        pendingLocal[index].failed = true
        updateRow(Self.userRowID(promptId: promptId, seq: 0)) { content in
            if case .user(var message) = content {
                message.failed = true
                message.isPending = false
                content = .user(message)
            }
        }
        removeTyping()
    }

    // MARK: - Filtering

    static func isRenderable(_ record: AcpmuxEventRecord) -> Bool {
        if record.isReplay { return false }
        switch record.dir {
        case "mux":
            return muxKinds.contains(record.kind)
        case "in":
            return record.sessionUpdate != nil && updateKinds.contains(record.kind)
        default:
            return false
        }
    }

    private static let muxKinds: Set<String> = [
        "user_message", "queued", "queue_updated", "queue_removed", "turn_started", "turn_end",
        "turn_result", "status", "permission_request", "permission_decision", "resume_failed", "failover",
    ]

    private static let updateKinds: Set<String> = [
        "agent_message_chunk", "agent_thought_chunk", "user_message_chunk", "tool_call", "tool_call_update", "plan",
    ]

    // MARK: - Reduction

    private mutating func rebuild() {
        let kept = records
        rows = []
        indexByID = [:]
        toolRowByCallID = [:]
        messageIDByRow = [:]
        turn = nil
        lastClosedTurn = nil
        let liveQueue = queue
        let liveStatus = status
        for record in kept { reduce(record) }
        // Queue and status describe the present; replaying older history must not rewind them.
        queue = liveQueue
        status = liveStatus
        for local in pendingLocal where indexByID[Self.userRowID(promptId: local.promptId, seq: 0)] == nil {
            insertPending(local)
        }
    }

    private mutating func reduce(_ record: AcpmuxEventRecord) {
        if record.dir == "mux" {
            reduceMux(record)
        } else if let update = record.sessionUpdate {
            reduceUpdate(update, record: record)
        }
    }

    private mutating func reduceMux(_ record: AcpmuxEventRecord) {
        let msg = record.msg
        switch record.kind {
        case "user_message":
            let promptId = msg["promptId"]?.stringValue
            if let promptId {
                queue.removeAll { $0.promptId == promptId }
                pendingLocal.removeAll { $0.promptId == promptId }
            }
            let text = msg["text"]?.stringValue ?? ""
            let steersRunningTurn = msg["steer"]?.boolValue == true && turn != nil
            if !steersRunningTurn, turn == nil || turn?.hasOutput == true {
                // Old logs have no turn_started; a user message opens the turn.
                closeTurn(at: record.at, status: nil, error: nil, emitSummary: turn?.hasOutput == true)
                openTurn(key: record.seq, at: record.at)
            }
            turn?.sawUserMessage = true
            let rowID = Self.userRowID(promptId: promptId, seq: record.seq)
            if indexByID[rowID] != nil {
                updateRow(rowID) { $0 = .user(TranscriptUserMessage(text: text)) }
            } else {
                removeTyping()
                append(TranscriptRow(id: rowID, at: record.at, content: .user(TranscriptUserMessage(text: text))))
            }
            ensureTyping(at: record.at)
        case "turn_started":
            if turn == nil || turn?.hasOutput == true {
                closeTurn(at: record.at, status: nil, error: nil, emitSummary: turn?.hasOutput == true)
                openTurn(key: record.seq, at: record.at)
            }
            turn?.startedSeq = record.seq
            ensureTyping(at: record.at)
        case "turn_end":
            guard turn != nil else { return }
            let stop = msg["stopReason"]?.stringValue
            closeTurn(at: record.at, status: stop == "cancelled" ? "cancelled" : "completed", error: nil, emitSummary: true)
        case "turn_result":
            let status = msg["status"]?.stringValue ?? "completed"
            let error = msg["error"]?.stringValue
            if turn != nil {
                closeTurn(at: record.at, status: status, error: error, emitSummary: true)
            } else if let closed = lastClosedTurn,
                      closed.startedSeq == nil || closed.startedSeq == msg["turnSeq"]?.intValue,
                      let index = indexByID[closed.rowID] {
                // turn_end already closed the turn; turn_result refines its status.
                rows[index].update { content in
                    if case .turnSummary(var summary) = content {
                        summary.status = status
                        summary.error = error
                        content = .turnSummary(summary)
                    }
                }
            }
        case "status":
            status = msg["status"]?.stringValue
        case "queued", "queue_updated":
            guard let promptId = msg["promptId"]?.stringValue else { return }
            let entry = AcpmuxQueueEntry(
                promptId: promptId,
                text: msg["text"]?.stringValue,
                delivery: msg["delivery"]?.stringValue
            )
            if let index = queue.firstIndex(where: { $0.promptId == promptId }) {
                queue[index] = entry
            } else {
                queue.append(entry)
            }
        case "queue_removed":
            guard let promptId = msg["promptId"]?.stringValue else { return }
            queue.removeAll { $0.promptId == promptId }
        case "permission_request":
            guard let permissionId = msg["permissionId"]?.stringValue,
                  let request = msg["request"].flatMap(Self.decodePermissionRequest) else { return }
            markOutput()
            let rowID = "perm-\(permissionId)"
            guard indexByID[rowID] == nil else { return }
            removeTyping()
            append(TranscriptRow(
                id: rowID,
                at: record.at,
                content: .permission(TranscriptPermissionCard(permissionId: permissionId, request: request, resolution: nil))
            ))
        case "permission_decision":
            guard let permissionId = msg["permissionId"]?.stringValue else { return }
            let outcome = msg["outcome"]
            updateRow("perm-\(permissionId)") { content in
                guard case .permission(var card) = content else { return }
                if outcome?["outcome"]?.stringValue == "selected", let optionId = outcome?["optionId"]?.stringValue {
                    let allowed = card.request.options.first { $0.optionId == optionId }?.isAllow ?? true
                    card.resolution = .selected(optionId: optionId, allowed: allowed)
                } else {
                    card.resolution = .cancelled
                }
                content = .permission(card)
            }
        case "resume_failed", "failover":
            let text = msg["error"]?.stringValue ?? msg["reason"]?.stringValue ?? record.kind
            append(TranscriptRow(id: "notice-\(record.seq)", at: record.at, content: .notice(text)))
        default:
            break
        }
    }

    private mutating func reduceUpdate(_ update: JSONValue, record: AcpmuxEventRecord) {
        switch record.kind {
        case "agent_message_chunk":
            guard let text = Self.contentText(update["content"]) else { return }
            markOutput()
            let messageID = update["messageId"]?.stringValue
            if let last = rows.last, case .assistant(let existing, _) = last.content, isLastRowInCurrentTurn,
               continuesMessage(rowID: last.id, messageID: messageID) {
                updateRow(last.id) { $0 = .assistant(text: existing + text, isStreaming: true) }
                return
            }
            // A new messageId starts a new bubble. When it directly follows an unfinished
            // message and restarts the same text, the agent is redelivering after a dropped
            // stream (Codex does this): the abandoned partial row goes away.
            if let last = rows.last, case .assistant(let existing, true) = last.content, isLastRowInCurrentTurn,
               messageID != nil, messageIDByRow[last.id] != nil,
               Self.isRedelivery(of: existing, restartingWith: text) {
                removeRow(last.id)
            }
            let rowID = "msg-\(record.seq)"
            if let messageID { messageIDByRow[rowID] = messageID }
            appendStreaming(TranscriptRow(id: rowID, at: record.at, content: .assistant(text: text, isStreaming: turn != nil)))
        case "agent_thought_chunk":
            guard let text = Self.contentText(update["content"]) else { return }
            markOutput()
            appendActivity(.thought(text), record: record, mergeThought: true, messageID: update["messageId"]?.stringValue)
        case "user_message_chunk":
            guard turn?.sawUserMessage != true, let text = Self.contentText(update["content"]) else { return }
            if let last = rows.last, case .user(var message) = last.content, last.id.hasPrefix("uchunk-") {
                message.text += text
                updateRow(last.id) { $0 = .user(message) }
            } else {
                removeTyping()
                append(TranscriptRow(id: "uchunk-\(record.seq)", at: record.at, content: .user(TranscriptUserMessage(text: text))))
            }
        case "tool_call":
            guard let callID = update["toolCallId"]?.stringValue else { return }
            markOutput()
            if toolRowByCallID[callID] != nil {
                updateTool(callID, with: update)
                return
            }
            turn?.toolCount += 1
            let call = TranscriptToolCall(
                id: callID,
                title: update["title"]?.stringValue ?? callID,
                kind: update["kind"]?.stringValue,
                status: update["status"]?.stringValue ?? "pending",
                inputSummary: Self.inputSummary(update["rawInput"], locations: update["locations"]),
                output: Self.outputText(update)
            )
            appendActivity(.tool(call), record: record, mergeThought: false)
        case "tool_call_update":
            guard let callID = update["toolCallId"]?.stringValue else { return }
            if toolRowByCallID[callID] == nil {
                // An update for a call outside the loaded window still shows up.
                markOutput()
                turn?.toolCount += 1
                let call = TranscriptToolCall(
                    id: callID,
                    title: update["title"]?.stringValue ?? callID,
                    kind: update["kind"]?.stringValue,
                    status: update["status"]?.stringValue ?? "in_progress",
                    inputSummary: Self.inputSummary(update["rawInput"], locations: update["locations"]),
                    output: Self.outputText(update)
                )
                appendActivity(.tool(call), record: record, mergeThought: false)
            } else {
                updateTool(callID, with: update)
            }
        case "plan":
            let entries = (update["entries"]?.arrayValue ?? []).compactMap { entry -> TranscriptPlanEntry? in
                guard let content = entry["content"]?.stringValue else { return nil }
                return TranscriptPlanEntry(content: content, status: entry["status"]?.stringValue ?? "pending")
            }
            markOutput()
            let rowID = "plan-\(turn?.key ?? record.seq)"
            if indexByID[rowID] != nil {
                updateRow(rowID) { $0 = .plan(entries) }
            } else {
                removeTyping()
                append(TranscriptRow(id: rowID, at: record.at, content: .plan(entries)))
            }
        default:
            break
        }
    }

    // MARK: - Turn bookkeeping

    private mutating func openTurn(key: Int, at: Int64) {
        turn = TurnState(key: key, startAt: at)
    }

    private mutating func closeTurn(at: Int64, status: String?, error: String?, emitSummary: Bool) {
        guard let current = turn else { return }
        removeTyping()
        for rowID in current.streamingRowIDs {
            updateRow(rowID) { content in
                switch content {
                case .assistant(let text, true): content = .assistant(text: text, isStreaming: false)
                case .activity(var group) where group.isLive:
                    group.isLive = false
                    content = .activity(group)
                default: break
                }
            }
        }
        turn = nil
        guard emitSummary, current.hasOutput || status != nil else { return }
        let summary = TranscriptTurnSummary(
            durationMs: current.startAt.map { max(0, at - $0) },
            toolCount: current.toolCount,
            status: status ?? "completed",
            error: error
        )
        let rowID = Self.summaryRowID(current.key)
        lastClosedTurn = (current.startedSeq, rowID)
        if indexByID[rowID] == nil {
            append(TranscriptRow(id: rowID, at: at, content: .turnSummary(summary)))
        }
    }

    private mutating func markOutput() {
        if turn == nil {
            // Output with no visible turn start (history window began mid-turn).
            openTurn(key: lastSeq, at: 0)
            turn?.startAt = nil
        }
        turn?.hasOutput = true
        removeTyping()
    }

    private var isLastRowInCurrentTurn: Bool {
        guard let last = rows.last, let current = turn else { return false }
        return current.streamingRowIDs.contains(last.id)
    }

    private mutating func appendStreaming(_ row: TranscriptRow) {
        removeTyping()
        append(row)
        turn?.streamingRowIDs.append(row.id)
    }

    private mutating func appendActivity(
        _ item: TranscriptActivityItem,
        record: AcpmuxEventRecord,
        mergeThought: Bool,
        messageID: String? = nil
    ) {
        if let last = rows.last, case .activity(var group) = last.content, isLastRowInCurrentTurn {
            if mergeThought, case .thought(let text)? = group.items.last, case .thought(let more) = item,
               continuesMessage(rowID: last.id, messageID: messageID) {
                group.items[group.items.count - 1] = .thought(text + more)
            } else {
                group.items.append(item)
            }
            if mergeThought, let messageID { messageIDByRow[last.id] = messageID }
            if case .tool(let call) = item { toolRowByCallID[call.id] = last.id }
            updateRow(last.id) { $0 = .activity(group) }
            return
        }
        let rowID = "act-\(record.seq)"
        if case .tool(let call) = item { toolRowByCallID[call.id] = rowID }
        if mergeThought, let messageID { messageIDByRow[rowID] = messageID }
        appendStreaming(TranscriptRow(
            id: rowID,
            at: record.at,
            content: .activity(TranscriptActivityGroup(items: [item], isLive: turn != nil))
        ))
    }

    private mutating func updateTool(_ callID: String, with update: JSONValue) {
        guard let rowID = toolRowByCallID[callID] else { return }
        updateRow(rowID) { content in
            guard case .activity(var group) = content else { return }
            for index in group.items.indices {
                guard case .tool(var call) = group.items[index], call.id == callID else { continue }
                if let title = update["title"]?.stringValue { call.title = title }
                if let kind = update["kind"]?.stringValue { call.kind = kind }
                if let status = update["status"]?.stringValue { call.status = status }
                if let summary = Self.inputSummary(update["rawInput"], locations: update["locations"]) { call.inputSummary = summary }
                if let output = Self.outputText(update) { call.output = output }
                group.items[index] = .tool(call)
            }
            content = .activity(group)
        }
    }

    /// Whether a chunk with `messageID` continues the message streaming into `rowID`.
    private func continuesMessage(rowID: String, messageID: String?) -> Bool {
        guard let messageID, let current = messageIDByRow[rowID] else { return true }
        return current == messageID
    }

    /// Whether a new message that begins with `start` restarts `abandoned`.
    static func isRedelivery(of abandoned: String, restartingWith start: String) -> Bool {
        let head = start.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return false }
        return abandoned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(head)
    }

    private mutating func removeRow(_ rowID: String) {
        guard let index = indexByID[rowID] else { return }
        rows.remove(at: index)
        indexByID[rowID] = nil
        messageIDByRow[rowID] = nil
        turn?.streamingRowIDs.removeAll { $0 == rowID }
        reindex(from: index)
    }

    // MARK: - Typing indicator and local echoes

    private mutating func ensureTyping(at: Int64) {
        guard let current = turn, !current.hasOutput else { return }
        let rowID = "typing"
        guard indexByID[rowID] == nil else { return }
        append(TranscriptRow(id: rowID, at: at, content: .typing))
    }

    private mutating func removeTyping() {
        guard let index = indexByID["typing"] else { return }
        rows.remove(at: index)
        reindex(from: index)
    }

    private mutating func insertPending(_ local: PendingLocalMessage) {
        removeTyping()
        append(TranscriptRow(
            id: Self.userRowID(promptId: local.promptId, seq: 0),
            at: local.at,
            content: .user(TranscriptUserMessage(text: local.text, isPending: !local.failed, failed: local.failed))
        ))
        if !local.failed {
            append(TranscriptRow(id: "typing", at: local.at, content: .typing))
        }
    }

    // MARK: - Row storage

    private mutating func append(_ row: TranscriptRow) {
        if let typing = indexByID["typing"], row.id != "typing" {
            // Keep the typing indicator last.
            rows.insert(row, at: typing)
            reindex(from: typing)
            return
        }
        indexByID[row.id] = rows.count
        rows.append(row)
    }

    private mutating func updateRow(_ rowID: String, _ transform: (inout TranscriptRowContent) -> Void) {
        guard let index = indexByID[rowID] else { return }
        rows[index].update(transform)
    }

    private mutating func reindex(from start: Int) {
        for index in rows.indices where index >= start {
            indexByID[rows[index].id] = index
        }
        indexByID = indexByID.filter { $0.value < rows.count && rows[$0.value].id == $0.key }
    }

    // MARK: - Payload helpers

    /// The row id a user message with `promptId` gets.
    public static func userRowID(promptId: String?, seq: Int) -> String {
        if let promptId { return "user-\(promptId)" }
        return "user-\(seq)"
    }

    static func summaryRowID(_ turnKey: Int) -> String { "turn-\(turnKey)" }

    static func contentText(_ content: JSONValue?) -> String? {
        guard let content, content["type"]?.stringValue == "text" else { return nil }
        return content["text"]?.stringValue
    }

    static func decodePermissionRequest(_ value: JSONValue) -> AcpmuxPermissionRequest? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(AcpmuxPermissionRequest.self, from: data)
    }

    static func inputSummary(_ rawInput: JSONValue?, locations: JSONValue?) -> String? {
        if let command = rawInput?["command"] {
            if let text = command.stringValue { return text }
            if let parts = command.arrayValue?.compactMap(\.stringValue), !parts.isEmpty { return parts.joined(separator: " ") }
        }
        for key in ["file_path", "path", "pattern", "query", "url"] {
            if let text = rawInput?[key]?.stringValue { return text }
        }
        if let path = locations?.arrayValue?.first?["path"]?.stringValue { return path }
        return nil
    }

    /// Longest tool output kept per call. Tool output can be megabytes; the row shows a preview.
    static let outputLimit = 4_000

    static func outputText(_ update: JSONValue) -> String? {
        var pieces: [String] = []
        for item in update["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "content":
                if let text = contentText(item["content"]) { pieces.append(text) }
            case "diff":
                if let path = item["path"]?.stringValue { pieces.append(path) }
            default:
                continue
            }
        }
        if pieces.isEmpty, let formatted = update["rawOutput"]?["formatted_output"]?.stringValue {
            pieces.append(formatted)
        }
        guard !pieces.isEmpty else { return nil }
        let text = pieces.joined(separator: "\n")
        return text.count > outputLimit ? String(text.prefix(outputLimit)) + "…" : text
    }
}
