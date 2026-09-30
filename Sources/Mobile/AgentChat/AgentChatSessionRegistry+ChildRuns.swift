import CMUXAgentLaunch
import CmuxMobileHost
import Foundation

/// Child-run (subagent) bookkeeping from the parent session's hook events.
///
/// Two shapes exist on the wire. Claude spawns children through its spawn
/// tool, named `Task` before 2.x and `Agent` after (both are still on the
/// wire; see `isTaskSpawn`), so a child's life is bracketed by that tool's
/// `PreToolUse`/`PostToolUse` pair (the payload carries `description` and
/// `subagent_type`). Codex, pi and OMP emit dedicated
/// `SubagentStart`/`SubagentStop` events instead. Neither child ever runs
/// hooks of its own, so this bookkeeping is
/// the ONLY view cmux has of nested agents; the state machine in
/// `nextState(previous:event:)` deliberately keeps ignoring these events (a
/// child's lifecycle says nothing about whether the PARENT is working).
///
/// Honest limits: a background spawn returns from `PostToolUse` immediately
/// while the child keeps running, so background children read as settled the
/// moment they detach; without per-child ids from the CLI, a `stop`/`Stop`
/// closes every open child (a stopped parent has no running foreground
/// children). Claude straddles both shapes rather than only the first: it
/// emits `SubagentStop` too (`CMUXCLI+ClaudeHookSettings` installs the hook,
/// `FeedEventClassifier` maps it), and `requestId` decodes only
/// `_opencode_request_id`, so for Claude both that event and the spawn
/// tool's `PostToolUse` fall through to the FIFO branch of `closeChild` and
/// one child closes two rows. With parallel spawns that settles a sibling
/// early; fixing it needs a correlation id or a per-source rule, not a
/// comment.
extension AgentChatSessionRegistry {
    nonisolated static func applyChildRunEvent(
        _ record: inout AgentChatSessionRecord,
        event: WorkstreamEvent
    ) {
        switch event.hookEventName {
        case .preToolUse where isTaskSpawn(event):
            openChild(
                &record,
                id: event.requestId ?? UUID().uuidString,
                label: taskLabel(from: event.toolInputJSON),
                at: event.receivedAt
            )
        case .postToolUse where isTaskSpawn(event):
            closeChild(&record, id: event.requestId, at: event.receivedAt)
        case .subagentStart:
            openChild(
                &record,
                id: event.requestId ?? UUID().uuidString,
                label: taskLabel(from: event.toolInputJSON),
                at: event.receivedAt
            )
        // Claude's SubagentStop duplicates the spawn tool's PostToolUse. Its
        // requestId is nil, so processing it would FIFO-close a sibling.
        case .subagentStop where event.source != "claude":
            closeChild(&record, id: event.requestId, at: event.receivedAt)
        case .stop, .sessionEnd:
            // The parent finished its turn (or ended); foreground children
            // cannot still be running.
            for index in record.children.indices where record.children[index].endedAt == nil {
                record.children[index].endedAt = event.receivedAt
            }
        default:
            break
        }
        prune(&record, now: event.receivedAt)
    }

    private nonisolated static func isTaskSpawn(_ event: WorkstreamEvent) -> Bool {
        // Claude Code renamed the spawn tool "Task" -> "Agent" (2.x); both
        // names remain on the wire depending on CLI version.
        event.toolName == "Task" || event.toolName == "Agent"
    }

    private nonisolated static func openChild(
        _ record: inout AgentChatSessionRecord,
        id: String,
        label: String?,
        at date: Date
    ) {
        // A repeated PreToolUse for the same request (retries) must not fork
        // a duplicate child.
        if record.children.contains(where: { $0.id == id && $0.endedAt == nil }) { return }
        record.children.append(AgentChatChildRun(id: id, label: label, startedAt: date))
    }

    private nonisolated static func closeChild(
        _ record: inout AgentChatSessionRecord,
        id: String?,
        at date: Date
    ) {
        if let id, let index = record.children.firstIndex(where: { $0.id == id && $0.endedAt == nil }) {
            record.children[index].endedAt = date
            return
        }
        // No correlation id on the wire: close the OLDEST open child (FIFO:
        // parallel spawn fan-outs finish roughly in start order more often
        // than not, and a mismatch only swaps two elapsed labels).
        if let index = record.children.firstIndex(where: { $0.endedAt == nil }) {
            record.children[index].endedAt = date
        }
    }

    private nonisolated static func prune(_ record: inout AgentChatSessionRecord, now: Date) {
        record.children.removeAll { child in
            guard let endedAt = child.endedAt else { return false }
            return now.timeIntervalSince(endedAt) > AgentChatChildRun.settledRetention
        }
        if record.children.count > AgentChatChildRun.capacity {
            // Drop settled children first, oldest first; running ones stay.
            var overflow = record.children.count - AgentChatChildRun.capacity
            record.children.removeAll { child in
                guard overflow > 0, child.endedAt != nil else { return false }
                overflow -= 1
                return true
            }
        }
    }

    /// The spawn payload's human-readable label: `description`, falling
    /// back to `subagent_type`.
    private nonisolated static func taskLabel(from toolInputJSON: String?) -> String? {
        guard let toolInputJSON,
              let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let description, !description.isEmpty { return description }
        let type = (object["subagent_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (type?.isEmpty == false) ? type : nil
    }
}
