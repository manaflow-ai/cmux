import CmuxAgentQuestion
import CmuxMobileAgentChat
import Foundation

/// Maps acpmux records (`Event = {sessionId, seq, at, dir, kind, msg}` from
/// `_acpmux/attach`, `_acpmux/events` and `_acpmux/event`) to chat events.
struct AcpmuxRecords {
    let sessionID: String

    /// One record's chat events (empty for records the chat does not draw).
    func map(_ record: JSONValue) -> [AgentSessionEvent] {
        let at = record["at"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let msg = record["msg"] ?? .null
        let kind = record["kind"]?.stringValue ?? ""
        switch record["dir"]?.stringValue {
        case "in":
            // eventStream form: msg = {method: session/update, params: {update}}; raw form: msg.params.update too.
            // acpmux writes subagent attribution into `params._meta.acpmux` (cmux-tui acpmux/src/subagents.rs).
            // Claude Code's raw `system/api_retry` line (acpmux logs it as `claude.system.api_retry`).
            if kind == "claude.system.api_retry" {
                let line = msg["params"] ?? msg
                return [.retrying(attempt: Int(line["attempt"]?.numberValue ?? 0),
                                  maxAttempts: Int(line["max_retries"]?.numberValue ?? 0),
                                  status: line["error_status"]?.numberValue.map { Int($0) })]
            }
            let mux = msg["params"]?["_meta"]?["acpmux"] ?? msg["_meta"]?["acpmux"]
            var events: [AgentSessionEvent] = (mux?["subagents"]?.arrayValue ?? []).compactMap {
                AgentSubagentChange($0, at: at).map(AgentSessionEvent.subagent)
            }
            guard let update = msg["params"]?["update"] ?? msg["update"],
                  let decoded = try? Self.decode(ACPSessionUpdate.self, update) else { return events }
            if let owner = mux?["subagent"]?.stringValue {
                events.append(.subagentUpdate(subagentID: owner, decoded))
            } else {
                events.append(.update(decoded))
            }
            return events
        case "mux":
            var events = mux(kind, msg, at: at)
            // A fork through this turn names its record (`acp.session.fork {throughSeq}`).
            if kind == "turn_result", let turnID = msg["turnId"]?.stringValue, let seq = record["seq"]?.numberValue {
                events.append(.turnSeq(turnId: turnID, seq: Int(seq)))
            }
            return events
        default:
            return []
        }
    }

    func mux(_ kind: String, _ msg: JSONValue, at: Date) -> [AgentSessionEvent] {
        switch kind {
        case "user_message":
            guard let turnID = msg["turnId"]?.stringValue else { return [] }
            // The images the prompt sent (acpmux keeps their bytes; `_acpmux/attachment` reads them).
            let recorded = msg["images"]?.arrayValue ?? []
            // A video's frames, their note and labels went to the agent only (the Mac's bubble leaves them out).
            let imageNames = recorded.map { $0["name"]?.stringValue }
            let images = recorded.enumerated().compactMap { index, image -> AgentAttachment? in
                guard let id = image["id"]?.stringValue, !id.isEmpty, !AgentVideo.isFrameName(image["name"]?.stringValue) else { return nil }
                return .recordedImage(id: id, name: image["name"]?.stringValue, index: index)
            }
            var events: [AgentSessionEvent] = []
            if let retry = msg["_meta"]?["provenance"], retry["kind"]?.stringValue == "auto_resume",
               let previous = retry["turnId"]?.stringValue, previous != turnID {
                events.append(.turnRetried(previousTurnID: previous, turnID: turnID))
            }
            events.append(.userMessage(text: AgentVideo.withoutFrameText(msg["text"]?.stringValue ?? "", imageNames: imageNames), promptId: msg["promptId"]?.stringValue ?? turnID,
                                 turnId: turnID, attachments: images, at: at))
            return events
        case "queued":
            guard let promptID = msg["promptId"]?.stringValue else { return [] }
            return [.queued(text: msg["text"]?.stringValue ?? "", promptId: promptID, position: Int(msg["position"]?.numberValue ?? 0))]
        case "dequeued":
            guard let promptID = msg["promptId"]?.stringValue else { return [] }
            return [.dequeued(promptId: promptID)]
        case "queue_updated":
            guard let promptID = msg["promptId"]?.stringValue else { return [] }
            return [.queueUpdated(promptId: promptID, text: msg["text"]?.stringValue ?? "")]
        case "queue_order":
            guard case .array(let ids)? = msg["order"] else { return [] }
            return [.queueOrder(ids.compactMap(\.stringValue))]
        case "queue_paused":
            return [.queuePaused(true, reason: msg["reason"]?.stringValue)]
        case "queue_resumed":
            return [.queuePaused(false, reason: nil)]
        case "turn_started":
            guard let turnID = msg["turnId"]?.stringValue else { return [] }
            return [.turnStarted(turnId: turnID, at: at)]
        case "turn_result":
            guard let turnID = msg["turnId"]?.stringValue else { return [] }
            let status: AgentTurn.Status = switch msg["status"]?.stringValue {
            case "cancelled": .cancelled
            case "failed": .failed
            default: .completed
            }
            return [.turnResult(turnId: turnID, status: status, errorText: msg["errorText"]?.stringValue ?? msg["error"]?.stringValue, at: at)]
        case "permission_request":
            guard let permissionID = msg["permissionId"]?.stringValue, let request = msg["request"] else { return [] }
            return permission(permissionID, request: request).map { [$0] } ?? []
        case "permission_decision":
            guard let permissionID = msg["permissionId"]?.stringValue else { return [] }
            let outcome = msg["outcome"]
            let optionID = outcome?["outcome"]?.stringValue == "selected" ? outcome?["optionId"]?.stringValue : nil
            // A question's answers, as acpmux put them into the tool's input.
            let answers = outcome?["_meta"]?["updatedInput"]?["answers"].flatMap { try? Self.convert($0, to: AgentQuestionJSON.self) }
            return [.permissionDecision(permissionId: permissionID, optionId: optionID, answers: answers)]
        default:
            return []
        }
    }

    /// A `permission_request` body as a question (AskUserQuestion and kin) or a tool permission.
    func permission(_ permissionID: String, request: JSONValue) -> AgentSessionEvent? {
        if let json = try? Self.convert(request, to: AgentQuestionJSON.self),
           let question = AgentQuestion(permissionRequest: json, permissionId: permissionID, session: sessionID) {
            return .question(question)
        }
        guard let toolCall = request["toolCall"], let call = try? Self.decode(ACPToolCall.self, toolCall) else { return nil }
        let options = (try? Self.decode([ACPPermissionOption].self, request["options"] ?? .array([]))) ?? []
        return .permissionRequest(ACPPermissionRequest(id: permissionID, toolCall: call, options: options, cwd: request["cwd"]?.stringValue))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    static func convert<T: Decodable, U: Encodable>(_ value: U, to type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

/// acpmux `SessionSummary` fields the app reads.
public struct AcpmuxSession: Hashable, Sendable {
    public var id: String
    public var name: String
    public var harness: String
    public var cwd: String
    /// `peer`: the acpmux peer (another machine) the session runs on; nil for this Mac's own.
    public var peer: String?
    public var status: String
    public var indicator: String?
    public var preview: String?
    public var lastPrompt: String?
    public var pendingPermissions: Int
    public var lastSeq: Int
    public var updatedAt: Date?
    /// `lastTurn.status`: completed, cancelled or failed.
    public var lastTurnStatus: String?
    /// `lastTurn.turnId` and `lastTurn.endedAt`: the turn a Feed item is about.
    public var lastTurnID: String?
    public var lastTurnEndedAt: Date?
    /// `lastTurn.errorText`: why the last turn failed, in the agent's words.
    public var lastTurnError: String?

    init?(_ value: JSONValue) {
        guard let id = value["sessionId"]?.stringValue else { return nil }
        self.id = id
        name = value["name"]?.stringValue ?? ""
        harness = value["harness"]?.stringValue ?? "agent"
        cwd = value["cwd"]?.stringValue ?? ""
        peer = value["peer"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        status = value["status"]?.stringValue ?? "idle"
        indicator = value["indicator"]?.stringValue
        preview = value["preview"]?.stringValue
        lastPrompt = value["lastPrompt"]?.stringValue
        pendingPermissions = Int(value["pendingPermissions"]?.numberValue ?? 0)
        lastSeq = Int(value["lastSeq"]?.numberValue ?? 0)
        lastTurnStatus = value["lastTurn"]?["status"]?.stringValue
        lastTurnID = value["lastTurn"]?["turnId"]?.stringValue
        lastTurnEndedAt = value["lastTurn"]?["endedAt"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        lastTurnError = value["lastTurn"]?["errorText"]?.stringValue
        updatedAt = value["updatedAt"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    public var summaryStatus: AgentSessionSummary.Status {
        AgentSessionSummary.Status(rawValue: status) ?? .idle
    }
}
