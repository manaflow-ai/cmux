// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxMobileArtifacts
import Foundation

/// The mock session's history turn with subagents and artifacts, and its
/// offline checkpoints and handoff (the acpmux shapes, local data).
extension MockAgentSession {
    /// Two turns other agents' messages started, as acpmux records them: a lane VM's report the
    /// lane-gh broker relayed (its label left out of the card), then three that waited for the busy
    /// chat and went in as one digest (a stack). Read by the same parser the live chat uses.
    func replayAgentMessageTurns(at start: Date) {
        let label = { (id: String, from: String, body: String) in
            "[message \(id) from \(from) (an agent, not Leo), relayed by the lane-gh broker; its text ends at \"[end of message \(id)]\"]\n\(body)\n[end of message \(id)]"
        }
        let report = label("4f4d68ff", "build-box/lane-3",
                           "**#36125 is green** at `64d6b1b`; the exact-head review is a SHIP.\n\n- the send relay lists other machines' sessions\n- the audit names sender and target, never the text")
        let digest = """
        3 messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.

        [agent message 1 of 3] from build-box/lane-3

        \(label("a1b2c3d4", "build-box/lane-3", "Rebased on `feat-cmux-next`; CI is running."))

        [agent message 2 of 3] from coordinator

        Take the iOS half next; the parser is shared.

        [agent message 3 of 3] from studio-mac/codex-1

        \(label("9e8f7a6b", "studio-mac/codex-1", "**Review:** SHIP at `64d6b1b`."))
        """
        let named: JSONValue = .object(["kind": .string("agent_message"), "from": .string("fromAgent"),
                                        "fromName": .string("build-box/lane-3")])
        // As hub/digest.rs `digest_provenance` writes it: each part's own provenance names its
        // sending chat. Two of these sessions' ids hash to one tone, so the chat moves the second to
        // the next (AgentTones), as the Mac does.
        let part = { (from: String, session: String?) -> JSONValue in
            var part: [String: JSONValue] = ["from": .string(from)]
            if let session {
                part["provenance"] = .object(["kind": .string("agent_message"), "from": .string("acp:\(session)"),
                                              "fromName": .string(from)])
            }
            return .object(part)
        }
        let digested: JSONValue = .object(["kind": .string("agent_digest"), "messages": .array([
            part("build-box/lane-3", "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a02"),
            part("coordinator", "0193a6f2-7c41-7e0b-9d2a-5f1e8c3b4a09"),
            part("studio-mac/codex-1", nil),
        ])])
        // A Chief's turn sending this chat a task (acpmux `stamp_chief`): the Chief's blue bubble (CMUX-51).
        let fromChief: JSONValue = .object(["kind": .string("session_message"), "from": .string("optchat-home-12"),
                                            "fromName": .string("Chief"), "fromChief": .string("agent_mux")])
        for (index, (text, provenance, answer)) in [
            (report, named, "Noted: #36125 lands once its base-only reds are confirmed."),
            (digest, digested, "Taking the iOS half; the review's SHIP is at the head."),
            ("Please rebase **#36125** on `feat-cmux-next` and post the exact-head build.", fromChief,
             "Rebasing now; I'll post the build when it is green."),
        ].enumerated() {
            let turnID = "history-agent-\(index)"
            let at = start.addingTimeInterval(Double(index) * 120)
            emit(.userMessage(text: text, promptId: "p-\(turnID)", turnId: turnID, attachments: [], at: at))
            if let incoming = AgentIncoming.parse(text: text, provenance: provenance) {
                emit(.promptFrom(turnId: turnID, incoming: incoming))
            }
            emit(.turnStarted(turnId: turnID, at: at))
            emit(.update(.agentMessageChunk(text: answer, messageId: "\(turnID)-m")))
            emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: at.addingTimeInterval(8)))
        }
    }

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

    /// Claude's acpmux `who_else` MCP call (`mcp__acpmux__who_else`) before it reads a file: three
    /// other sessions, a peer's named with its machine, one matched by topic, and one machine that did
    /// not answer (the Mac's `WhoElseCard.gallery.ts` claude state). Draws as the who-else card.
    func replayWhoElseCall() {
        let minute = 60_000.0
        func file(_ path: String, _ edited: Bool) -> JSONValue {
            .object(["path": .string("cmux-next-ios/rust/cmux-mobile-link/src/\(path)"), "edited": .bool(edited)])
        }
        func session(_ id: String, name: String, host: String? = nil, harness: String, live: Bool, branch: String, pulls: [String],
                     ago: Double, files: [JSONValue], inCommon: Int, topic: [String] = []) -> JSONValue {
            var object: [String: JSONValue] = [
                "sessionId": .string(id), "name": .string(name), "ref": .string(host.map { "\($0)/\(name)" } ?? name),
                "harness": .string(harness), "status": .string(live ? "running" : "idle"), "live": .bool(live),
                "branch": .string(branch), "pullRequests": .array(pulls.map { .string("https://github.com/manaflow-ai/cmux/pull/\($0)") }),
                "agoMs": .number(ago), "filesInCommon": .number(Double(inCommon)),
                "editedInCommon": .number(Double(files.count(where: { $0["edited"] == .bool(true) }))),
                "files": .array(files), "sameWorktree": .bool(false), "sameBranch": .bool(false),
                "topicWords": .array(topic.map(JSONValue.string)),
            ]
            if let host { object["host"] = .string(host) }
            return .object(object)
        }
        let answer: JSONValue = .object([
            "schema": .string(WhoElseCall.schema),
            "query": .object(["files": .array([.string("cmux-next-ios/rust/cmux-mobile-link/src/frame.rs")]), "fileCount": .number(1),
                              "topic": .string("link framing")]),
            "sessions": .array([
                session("who-dialer", name: "transport-switch", harness: "codex", live: true, branch: "lane/transport-switch",
                        pulls: ["36001"], ago: 4 * minute, files: [file("frame.rs", true), file("dial.rs", true), file("wg.rs", false)],
                        inCommon: 4),
                session("who-relay", name: "relay-probe", host: "my-vm", harness: "opencode", live: true, branch: "lane/relay-probe",
                        pulls: [], ago: 3 * 60 * minute, files: [file("frame.rs", false)], inCommon: 1),
                session("who-framing", name: "framing-docs", harness: "claude", live: false, branch: "lane/framing-docs",
                        pulls: ["35880"], ago: 26 * 60 * minute, files: [], inCommon: 0, topic: ["link", "framing"]),
            ]),
            "more": .number(0),
            "unreached": .array([.object(["host": .string("cosmic-gray"), "error": .string("no answer in 5 s")])]),
            "lines": .array([]),
        ])
        emit(.update(.toolCall(ACPToolCall(
            id: "h-who", title: "mcp__acpmux__who_else", kind: .other, status: .completed,
            content: [.content(.text("transport-switch (codex) edited frame.rs 4m ago"))],
            rawInput: .object(["files": .array([.string("cmux-next-ios/rust/cmux-mobile-link/src/frame.rs")]), "topic": .string("link framing")]),
            rawOutput: .object(["content": .array([.object(["type": .string("text"), "text": .string("…")])]), "structuredContent": answer])
        ))))
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
