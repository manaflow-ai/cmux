import CmuxNextDaemon
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// Agent hook events: feed.push attention events become daemon
/// notifications, agent_journal_append lifecycle events become the
/// surface's daemon agent state, and hook statuses reach the sidebar.
@Suite struct CompatFeedTests {
    @Test func attentionEventsMapToNotifications() {
        let permission = CompatFeed.attention(["hook_event_name": "PermissionRequest", "_source": "claude", "tool_name": "Bash"])
        #expect(permission == CompatFeed.Attention(title: "Claude needs permission", body: "Bash", needsDecision: true))
        let note = CompatFeed.attention(["hook_event_name": "Notification", "_source": "codex", "message": "done thinking"])
        #expect(note == CompatFeed.Attention(title: "Codex", body: "done thinking", needsDecision: false))
        #expect(CompatFeed.attention(["hook_event_name": "PostToolUse", "_source": "claude"]) == nil)
    }

    @Test func feedPushValidatesItsShape() throws {
        #expect(throws: ControlError.self) { try CompatFeed.events(["event": ["a": 1], "events": []]) }
        #expect(throws: ControlError.self) { try CompatFeed.events([:]) }
        #expect(try CompatFeed.events(["event": ["hook_event_name": "Stop"]]).count == 1)
        #expect(try CompatFeed.events(["session_id": "s", "hook_event_name": "Stop", "_source": "claude"]).count == 1)
    }

    @Test func journalKindsMapToAgentStates() {
        #expect(CompatFeed.agentState(kind: "agent.turn.started", pendingWork: false, declaredPhase: nil) == .working)
        #expect(CompatFeed.agentState(kind: "agent.turn.completed", pendingWork: false, declaredPhase: nil) == .idle)
        #expect(CompatFeed.agentState(kind: "agent.turn.completed", pendingWork: true, declaredPhase: nil) == .working)
        #expect(CompatFeed.agentState(kind: "agent.approval.requested", pendingWork: false, declaredPhase: nil) == .blocked)
        #expect(CompatFeed.agentState(kind: "agent.session.ended", pendingWork: false, declaredPhase: nil) == .done)
        #expect(CompatFeed.agentState(kind: "agent.state.changed", pendingWork: false, declaredPhase: "needs_input") == .blocked)
        #expect(CompatFeed.agentState(kind: "agent.message.published", pendingWork: false, declaredPhase: nil) == nil)
    }

    @Test func journalAppendAcknowledgesWithASequence() async {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        let unattributed = #"{"schema_version":1,"event_id":"e1","kind":"agent.turn.started","occurred_at_ms":1,"source":"claude","agent_key":"claude_code","unattributed_reason":"test","is_subagent":false,"pending_work":false}"#
        #expect(await router.response(forLine: "agent_journal_append \(unattributed)") == "OK 1")
        #expect(await router.response(forLine: "agent_journal_append \(unattributed)") == "OK 2")
        #expect(await router.response(forLine: "agent_journal_append").hasPrefix("ERROR: Usage"))
        #expect(await router.response(forLine: "agent_journal_append not-json") == "ERROR: invalid agent journal event")
    }

    @Test func hookStatusesFormTheSidebarLineAndNotify() {
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        let changed = RecordedStrings()
        service.observeSidebarStatus { changed.append($0) }
        service.sidebar.setStatus("claude_code", .init(value: "Running", priority: 10), workspace: "W1")
        service.sidebar.setStatus("build", .init(value: "compiling", priority: 80), workspace: "W1")
        #expect(service.sidebarStatusLine(workspace: "W1") == "compiling · Running")
        service.sidebar.setProgress((0.5, nil), workspace: "W1")
        #expect(service.sidebarStatusLine(workspace: "W1") == "compiling · Running · 50%")
        service.sidebar.clearStatus(nil, workspace: "W1")
        service.sidebar.setProgress(nil, workspace: "W1")
        #expect(service.sidebarStatusLine(workspace: "W1") == nil)
        #expect(changed.all == ["W1", "W1", "W1", "W1", "W1"])
    }
}

final class RecordedStrings: Sendable {
    private let values = Mutex<[String]>([])
    func append(_ value: String) { values.withLock { $0.append(value) } }
    var all: [String] { values.withLock { $0 } }
}
