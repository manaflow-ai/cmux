// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxMobileArtifacts
import Foundation

/// The mock session's history turn with subagents and artifacts, and its
/// offline checkpoints and handoff (the acpmux shapes, local data).
extension MockAgentSession {
    /// A finished turn that fanned out to three subagents and left a report,
    /// a screenshot, a recording, a PDF and links behind.
    func replaySubagentTurn(at start: Date) {
        let turnID = "history-2"
        let S = MockScript.self
        emit(.userMessage(text: "Audit the transport switch: check both dialers in parallel and write a report with a screenshot",
                          promptId: "p-h2", turnId: turnID,
                          attachments: [AgentAttachment(id: "att-1", kind: .image, name: "connection-settings.png", data: S.attachmentPNG)],
                          at: start))
        emit(.turnStarted(turnId: turnID, at: start))
        emit(.update(.agentThoughtChunk(text: "Two dialers and the relay can be checked independently; split them across subagents.")))
        let agents: [(id: String, name: String, task: String, call: String)] = [
            ("sa-webrtc", "WebRTC dialer", "Check the WebRTC dialer's ICE timeout and retry path", "tu-1"),
            ("sa-wg", "WireGuard dialer", "Check the WireGuard handshake and the relay fallback", "tu-2"),
            ("sa-tests", "Test runner", "Run the link tests and collect failures", "tu-3"),
        ]
        for (index, agent) in agents.enumerated() {
            let at = start.addingTimeInterval(Double(4 + index))
            emit(.update(.toolCall(ACPToolCall(id: agent.call, title: "Agent: \(agent.name)", kind: .other, status: .completed))))
            emit(.subagent(AgentSubagentChange(id: agent.id, name: agent.name, task: agent.task, state: .running, toolCallID: agent.call, at: at)))
        }
        // WebRTC subagent: reads and a finding.
        emitSub("sa-webrtc", .toolCall(ACPToolCall(id: "sw-r1", title: "Read dial.rs", kind: .read, status: .completed,
                                                   locations: [.init(path: "cmux-next-ios/rust/cmux-mobile-link/src/dial.rs", line: 88)])))
        emitSub("sa-webrtc", .toolCall(ACPToolCall(id: "sw-s1", title: "Search ice_timeout", kind: .search, status: .completed,
                                                   content: [.content(.text("cmux-next-ios/rust/cmux-mobile-link/src/webrtc.rs:41: let ice_timeout = Duration::from_secs(8);"))])))
        emitSub("sa-webrtc", .agentMessageChunk(text: "The ICE timeout is 8 s in `cmux-next-ios/rust/cmux-mobile-link/src/webrtc.rs`; with no TURN the first attempt on a LAN can time out once, then succeeds on retry.", messageId: "sw-m1"))
        // WireGuard subagent: a nested subagent for the relay.
        emitSub("sa-wg", .toolCall(ACPToolCall(id: "sg-r1", title: "Read wg.rs", kind: .read, status: .completed,
                                               locations: [.init(path: "cmux-next-ios/rust/cmux-mobile-link/src/wg.rs")])))
        emit(.subagent(AgentSubagentChange(id: "sa-relay", parent: "sa-wg", name: "Relay probe", task: "Measure the relay round trip over the Worker",
                                           state: .running, at: start.addingTimeInterval(9))))
        emitSub("sa-relay", .toolCall(ACPToolCall(id: "sr-x1", title: "Run relay-probe", kind: .execute, status: .completed,
                                                  content: [.content(.text("relay rtt p50 38 ms p95 61 ms\nwrote cmux-next-ios/verify/relay-rtt.csv"))],
                                                  rawInput: .object(["command": .string("cargo run -p cmux-mobile-link --example relay-probe")]))))
        emitSub("sa-relay", .agentMessageChunk(text: "Relay round trip: 38 ms median, 61 ms p95.", messageId: "sr-m1"))
        emit(.subagent(AgentSubagentChange(id: "sa-relay", state: .completed, at: start.addingTimeInterval(20))))
        emitSub("sa-wg", .agentMessageChunk(text: "Handshake retries are bounded; the relay fallback kicks in after 3 s without UDP.", messageId: "sg-m1"))
        // Test subagent: shell output with paths.
        emitSub("sa-tests", .toolCall(ACPToolCall(id: "st-x1", title: "Run swift test", kind: .execute, status: .completed,
                                                  content: [.content(.text(S.swiftTestOutput))],
                                                  rawInput: .object(["command": .string("swift test --filter LinkDialerTests")]),
                                                  rawOutput: .object(["exit_code": .number(0)]))))
        emitSub("sa-tests", .agentMessageChunk(text: "All 14 dialer tests pass.", messageId: "st-m1"))
        for (index, agent) in agents.enumerated() {
            emit(.subagent(AgentSubagentChange(id: agent.id, state: .completed, at: start.addingTimeInterval(Double(22 + index * 3)))))
        }
        // The report, a screenshot and a recording.
        emit(.update(.toolCall(ACPToolCall(
            id: "h2-w1", title: "Write transport-report.html", kind: .edit, status: .completed,
            content: [.diff(path: "cmux-next-ios/verify/transport-report.html", oldText: nil, newText: MockArtifactSource.reportHTML)],
            locations: [.init(path: "cmux-next-ios/verify/transport-report.html")]
        ))))
        emit(.update(.toolCall(ACPToolCall(
            id: "h2-x1", title: "Run simctl screenshot", kind: .execute, status: .completed,
            content: [.content(.text("Wrote cmux-next-ios/verify/screenshots/terminal.png\nWrote cmux-next-ios/verify/recordings/demo.mp4\nWrote cmux-next-ios/verify/transport-report.pdf"))],
            rawInput: .object(["command": .string("xcrun simctl io booted screenshot cmux-next-ios/verify/screenshots/terminal.png")]),
            rawOutput: .object(["exit_code": .number(0)])
        ))))
        emit(.update(.agentMessageChunk(text: S.subagentAnswer, messageId: "h2-m1")))
        emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: start.addingTimeInterval(41)))
    }

    private func emitSub(_ id: String, _ update: ACPSessionUpdate) {
        emit(.subagentUpdate(subagentID: id, update))
    }

    // MARK: Parity

    public var supportsCheckpoints: Bool { true }

    public func checkpoints() async throws -> [AgentCheckpoint] {
        try await sleep(.milliseconds(350))
        return checkpointLog.sorted { $0.createdAt > $1.createdAt }
    }

    public func restore(_ checkpoint: AgentCheckpoint) async throws -> String {
        try await sleep(.milliseconds(900))
        checkpointLog.append(AgentCheckpoint(id: "cp-restore-\(checkpointLog.count)", title: checkpoint.title, isBeforeTurn: true, createdAt: Date(),
                                             branch: summary.branch, head: "9f2c1ab", files: checkpoint.files,
                                             caption: "Before restoring “\(checkpoint.title)”"))
        return "Restored \(checkpoint.files) files"
    }

    public func handoffTargets() async throws -> [AgentHandoffTarget] {
        try await sleep(.milliseconds(300))
        let all = [
            AgentHandoffTarget(id: "codex", name: "Codex", family: "codex"),
            AgentHandoffTarget(id: "claude", name: "Claude Code", family: "claude"),
            AgentHandoffTarget(id: "opencode", name: "OpenCode", family: "opencode"),
            AgentHandoffTarget(id: "gemini", name: "Gemini CLI", family: "gemini", unavailableReason: "Not installed on \(summary.macName)"),
        ]
        return all.filter { $0.id != summary.harness }
    }

    public func prepareHandoff(to target: AgentHandoffTarget) async throws -> AgentHandoffDraft {
        try await sleep(.milliseconds(800))
        let capsule = """
        Continuing from \(summary.agentName) in \(summary.workspaceTitle) (\(summary.cwd)).

        Goal: make the link transport switchable between WebRTC and WireGuard.

        Done so far:
        - TransportKind and LinkDialer now pick the transport per Mac.
        - swift test --filter LinkDialerTests: 14 passed. cargo test -p cmux-mobile-link: 31 passed.
        - Report: cmux-next-ios/verify/transport-report.html.

        Next: add the Settings → Connection picker and record the switch on a phone.
        """
        return AgentHandoffDraft(id: "handoff-\(target.id)", revision: 1, target: target, capsule: capsule, coverage: [
            .init(item: "transcript", status: .summarized),
            .init(item: "tool_output", status: .summarized),
            .init(item: "plan", status: .included),
            .init(item: "files", status: .included),
            .init(item: "model", status: .omitted, detail: "The new agent uses its own model"),
        ])
    }

    public func startHandoff(_ draft: AgentHandoffDraft) async throws -> AgentHandoffReceipt {
        try await sleep(.milliseconds(900))
        return AgentHandoffReceipt(targetSessionID: "s-\(draft.target.id)-1", targetName: draft.target.name)
    }

    public var artifactSource: any ArtifactSource { MockArtifactSource() }
}
#endif
