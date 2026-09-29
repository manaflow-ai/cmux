import CmuxNextDaemon
import Foundation

/// Agent hook events from the old CLI, stored in the cmux-tui daemon:
///
/// - `feed.push` (v2): attention events (permission request, question,
///   plan review, agent notification) become daemon notifications (`notify`),
///   the store the sidebar unread badges and `notification.list` read. Other
///   events (tool use, prompts, session start) are acknowledged and not
///   stored: the daemon has no general event feed. cmux-next has no decision
///   UI, so a blocking push (`wait_timeout_seconds` > 0) answers `timed_out`
///   at once and the agent falls back to its own prompt.
/// - `agent_journal_append` (v1): lifecycle events update the surface's
///   agent state (`report-agent`: working, blocked, idle, done), which the
///   sidebar activity indicator shows. The daemon keeps no journal, so the
///   reply's sequence is this app process's counter, not a durable one.
enum CompatFeed {
    static let table: [String: CompatHandler] = ["feed.push": .async(push)]

    /// One hook event's notification, or nil for events the feed only acknowledges.
    struct Attention: Equatable {
        var title: String
        var body: String
        var needsDecision: Bool
    }

    static func attention(_ event: [String: JSON]) -> Attention? {
        let source = event["_source"]?.stringValue.map(sourceName) ?? "Agent"
        let tool = event["tool_name"]?.stringValue ?? ""
        let message = event["message"]?.stringValue ?? event["title"]?.stringValue ?? ""
        switch event["hook_event_name"]?.stringValue {
        case "PermissionRequest":
            return Attention(title: "\(source) needs permission", body: tool.isEmpty ? message : tool, needsDecision: true)
        case "AskUserQuestion":
            return Attention(title: "\(source) has a question", body: message, needsDecision: true)
        case "ExitPlanMode":
            return Attention(title: "\(source) plan ready for review", body: message, needsDecision: true)
        case "Notification":
            return Attention(title: source, body: message, needsDecision: false)
        default:
            return nil
        }
    }

    static func sourceName(_ slug: String) -> String {
        switch slug.lowercased() {
        case "claude", "claude_code", "claude-code": "Claude"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "pi": "Pi"
        default: slug.isEmpty ? "Agent" : slug.prefix(1).uppercased() + slug.dropFirst()
        }
    }

    static func events(_ params: [String: JSON]) throws -> [[String: JSON]] {
        guard params["event"] == nil || params["events"] == nil else {
            throw CompatErrors.invalid("feed.push accepts either `event` or `events`, not both")
        }
        if case .object(let event)? = params["event"] { return [event] }
        if case .array(let items)? = params["events"] {
            let events = items.compactMap { item -> [String: JSON]? in
                if case .object(let event) = item { return event }
                return nil
            }
            guard !events.isEmpty, events.count == items.count, events.count <= 64 else {
                throw CompatErrors.invalid("feed.push requires an `event` object")
            }
            return events
        }
        if params["session_id"] != nil, params["hook_event_name"] != nil, params["_source"] != nil { return [params] }
        throw CompatErrors.invalid("feed.push requires an `event` object")
    }

    static func push(_ call: CompatCall) async throws -> JSON {
        let wait = call.params["wait_timeout_seconds"]?.doubleValue ?? 0
        guard wait.isFinite, (0...120).contains(wait) else {
            throw CompatErrors.invalid("feed.push wait_timeout_seconds must be between 0 and 120")
        }
        let events = try events(call.params)
        let world = try await call.world()
        var ids: [JSON] = []
        var decision = false
        for event in events {
            guard let attention = attention(event) else { continue }
            decision = decision || attention.needsDecision
            let surface = event["surface_id"]?.stringValue.flatMap { try? world.resolveSurface($0, in: nil, refs: call.service.refs) }
            let handle = surface?.handle
            let id = try await call.service.daemon("notify") {
                try await $0.notify(title: attention.title, body: attention.body, surface: handle)
            }
            ids.append(.string(String(id.rawValue)))
        }
        var result: [String: JSON] = ["status": .string(wait > 0 && decision ? "timed_out" : "acknowledged"),
                                      "stored": .number(Double(ids.count))]
        if events.count > 1 { result["item_ids"] = .array(ids) } else if let id = ids.first { result["item_id"] = id }
        return .object(result)
    }

    // MARK: - agent_journal_append

    /// Daemon agent state for a journal event kind, or nil when the event
    /// does not change the surface's lifecycle.
    static func agentState(kind: String, pendingWork: Bool, declaredPhase: String?) -> AgentState? {
        switch kind {
        case "agent.turn.started", "agent.attention.resolved": return .working
        case "agent.turn.completed": return pendingWork ? .working : .idle
        case "agent.approval.requested", "agent.question.requested", "agent.plan_review.requested": return .blocked
        case "agent.session.started", "agent.idle.observed": return .idle
        case "agent.session.ended": return .done
        case "agent.state.changed":
            switch declaredPhase {
            case "running", "working": return .working
            case "needs_input", "blocked", "waiting": return .blocked
            case "idle": return .idle
            case "done", "ended": return .done
            default: return nil
            }
        default: return nil
        }
    }

    /// `agent_journal_append <event-json>`: `OK <seq>`, or the old error replies.
    static func journalAppend(_ payload: String, service: CompatService) async -> String {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "ERROR: Usage: agent_journal_append <event-json>" }
        guard case .object(let event)? = try? JSON.parse(Data(text.utf8)),
              let kind = event["kind"]?.stringValue, event["event_id"]?.stringValue != nil else {
            return "ERROR: invalid agent journal event"
        }
        let sequence = service.journal.next()
        let subagent = event["is_subagent"]?.boolValue ?? false
        guard !subagent,
              let state = agentState(kind: kind, pendingWork: event["pending_work"]?.boolValue ?? false,
                                     declaredPhase: event["declared_phase"]?.stringValue),
              let surfaceID = event["surface_id"]?.stringValue else { return "OK \(sequence)" }
        let session = event["session_id"]?.stringValue
        do {
            let world = try await service.world()
            let surface = try world.resolveSurface(surfaceID, in: nil, refs: service.refs)
            guard surface.isTerminal else { return "OK \(sequence)" }
            let handle = surface.handle
            _ = try await service.daemon("report-agent") {
                try await $0.request(ReportAgentRequest(surface: handle, state: state, session: session))
            }
            return "OK \(sequence)"
        } catch {
            // A surface that closed since the event is not an error for the hook.
            return "OK \(sequence)"
        }
    }
}
