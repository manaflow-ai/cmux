import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Agent activity evidence")
struct AgentActivityEvidenceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func event(_ subcommand: String, _ json: String) -> AgentHookActivityState.Event? {
        AgentHookActivityState.Event.parse(subcommand: subcommand, payload: Data(json.utf8))?.event
    }

    private func fold(_ events: [(String, String)]) -> AgentHookActivityState {
        var state = AgentHookActivityState()
        for (offset, (subcommand, json)) in events.enumerated() {
            if let event = event(subcommand, json) {
                state.apply(event, at: t0.addingTimeInterval(TimeInterval(offset)))
            }
        }
        return state
    }

    private func classify(_ evidence: AgentActivityEvidence) -> (AgentActivity, ResumeSafetyAssessment) {
        let result = AgentActivityClassifier.classify(evidence.signals)
        return (result.activity, result.safety)
    }

    @Test("a PreToolUse without its PostToolUse is an open Bash command")
    func openBash() {
        let hooks = fold([
            ("prompt-submit", #"{"session_id":"s"}"#),
            ("pre-tool-use", #"{"session_id":"s","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"swift test\n--parallel"}}"#),
        ])
        // started_at is the PreToolUse arrival time.
        #expect(hooks.openTool == AgentActivity.Tool(name: "Bash", command: "swift test --parallel", startedAt: t0.addingTimeInterval(1)))
        let (activity, safety) = classify(.init(registryState: .working(since: t0), registryHasHookLifecycleState: true,
                                                registryLastActivityAt: t0, hooks: hooks))
        #expect(activity.kind == .tool)
        #expect(activity.tool?.command == "swift test --parallel")
        #expect(safety.safety == .risky)
    }

    @Test("PostToolUse closes the call by tool_use_id and leaves the turn between tool calls")
    func betweenToolCalls() {
        let hooks = fold([
            ("prompt-submit", #"{"session_id":"s"}"#),
            ("pre-tool-use", #"{"tool_name":"Read","tool_use_id":"a","tool_input":{"file_path":"/x"}}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"ls"}}"#),
            ("post-tool-use", #"{"tool_name":"Bash","tool_use_id":"b"}"#),
        ])
        #expect(hooks.openTool?.name == "Read")
        let closed = fold([
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"ls"}}"#),
            ("post-tool-use", #"{"tool_name":"Bash","tool_use_id":"b"}"#),
        ])
        #expect(closed.openTool == nil)
        let (activity, safety) = classify(.init(registryState: .working(since: t0), registryHasHookLifecycleState: true,
                                                registryLastActivityAt: t0, hooks: closed))
        #expect(activity.kind == .thinking)
        #expect(safety.reasons == [.betweenToolCalls])
    }

    @Test("a tool inside a subagent outranks the Task launcher")
    func subagentTool() {
        let hooks = fold([
            ("pre-tool-use", #"{"tool_name":"Task","tool_use_id":"task","tool_input":{"description":"explore"}}"#),
            ("pre-tool-use", #"{"tool_name":"Grep","tool_use_id":"g","tool_input":{"pattern":"foo"}}"#),
        ])
        #expect(hooks.openTool?.name == "Grep")
        let afterGrep = fold([
            ("pre-tool-use", #"{"tool_name":"Task","tool_use_id":"task","tool_input":{"description":"explore"}}"#),
            ("pre-tool-use", #"{"tool_name":"Grep","tool_use_id":"g","tool_input":{"pattern":"foo"}}"#),
            ("post-tool-use", #"{"tool_name":"Grep","tool_use_id":"g"}"#),
        ])
        #expect(afterGrep.openTool?.name == "Task")
    }

    @Test("AskUserQuestion is a question even when the Feed overlay is lit")
    func question() {
        let hooks = fold([("pre-tool-use", #"{"tool_name":"AskUserQuestion","tool_input":{}}"#)])
        #expect(hooks.pendingQuestion)
        #expect(hooks.openTool == nil)
        let (activity, _) = classify(.init(registryState: .needsInput(since: t0), registryHasHookLifecycleState: true,
                                           registryLastActivityAt: t0, hooks: hooks, feedDecisionPending: true))
        #expect(activity.kind == .question)
        let answered = fold([
            ("pre-tool-use", #"{"tool_name":"AskUserQuestion","tool_input":{}}"#),
            ("post-tool-use", #"{"tool_name":"AskUserQuestion"}"#),
        ])
        #expect(!answered.pendingQuestion)
    }

    @Test("the Feed overlay without a hook question is a pending permission")
    func permission() {
        let (activity, safety) = classify(.init(registryState: .working(since: t0), registryHasHookLifecycleState: true,
                                                registryLastActivityAt: t0, hooks: nil, feedDecisionPending: true))
        #expect(activity.kind == .permission)
        #expect(safety.reasons == [.pendingPermission])
    }

    @Test("Stop with a running background task is background work and hides its process")
    func backgroundWork() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"npm run dev"}}"#),
            ("stop", #"{"background_tasks":[{"status":"running"}]}"#),
        ])
        #expect(hooks.backgroundWork)
        #expect(hooks.openTool == nil)
        let (activity, safety) = classify(.init(registryState: .idle, registryHasHookLifecycleState: true,
                                                registryLastActivityAt: t0, hooks: hooks, foregroundCommand: "npm run dev"))
        #expect(activity.kind == .background)
        #expect(safety.safety == .care)
    }

    @Test("an idle prompt notification after Stop is awaiting input")
    func awaitingInput() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("stop", #"{}"#),
            ("notification", #"{"notification_type":"idle_prompt"}"#),
        ])
        let (activity, safety) = classify(.init(registryState: .needsInput(since: t0), registryHasHookLifecycleState: true,
                                                registryLastActivityAt: t0, hooks: hooks))
        #expect(activity.kind == .awaitingInput)
        #expect(safety.safety == .safe)
    }

    @Test("without hook facts the registry lifecycle still decides")
    func registryOnly() {
        let working = classify(.init(registryState: .working(since: t0), registryHasHookLifecycleState: true,
                                     registryLastActivityAt: t0))
        #expect(working.0.kind == .thinking)
        #expect(working.0.since == t0)
        let discovered = classify(.init(registryState: .idle, registryHasHookLifecycleState: false,
                                        registryLastActivityAt: t0))
        #expect(discovered.0.kind == .unknown)
        let ended = classify(.init(registryState: .ended, registryHasHookLifecycleState: true, registryLastActivityAt: t0))
        #expect(ended.0.kind == .ended)
    }

    @Test("a foreground process decides when hooks are silent")
    func processOnly() {
        let (activity, safety) = classify(.init(registryState: .idle, registryHasHookLifecycleState: false,
                                                registryLastActivityAt: t0, foregroundCommand: "go test ./..."))
        #expect(activity.kind == .tool)
        #expect(activity.source == .process)
        #expect(safety.safety == .risky)
    }

    @Test("a new session in the pane starts clean and session end ends it")
    func sessionBoundaries() {
        let hooks = fold([
            ("pre-tool-use", #"{"tool_name":"Bash","tool_input":{"command":"x"}}"#),
            ("session-start", #"{"source":"startup"}"#),
        ])
        #expect(hooks == {
            var fresh = AgentHookActivityState()
            fresh.apply(.sessionStart(fresh: true), at: t0.addingTimeInterval(1))
            return fresh
        }())
        let ended = fold([("prompt-submit", #"{}"#), ("session-end", #"{}"#)])
        #expect(ended.ended)
        #expect(!ended.turnActive)
    }

    @Test("parse keeps the session id and ignores unrelated subcommands")
    func parse() {
        let parsed = AgentHookActivityState.Event.parse(
            subcommand: "post-tool-use", payload: Data(#"{"session_id":" abc ","tool_name":"Edit"}"#.utf8))
        #expect(parsed?.sessionID == "abc")
        #expect(parsed?.event == .postToolUse(id: nil, toolName: "Edit", subagent: false))
        #expect(AgentHookActivityState.Event.parse(subcommand: "feed", payload: Data("{}".utf8)) == nil)
        #expect(AgentHookActivityState.Event.parse(subcommand: "stop", payload: Data("[]".utf8)) == nil)
        #expect(AgentHookActivityState.Event.parse(subcommand: "pre-tool-use", payload: Data("{}".utf8)) == nil)
    }
}

@Suite("Agent hook activity review fixes")
struct AgentHookActivityReviewTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func fold(_ events: [(String, String)], relayBacked: Bool = false) -> AgentHookActivityState {
        var state = AgentHookActivityState()
        for (offset, (subcommand, json)) in events.enumerated() {
            if let event = AgentHookActivityState.Event.parse(
                subcommand: subcommand, payload: Data(json.utf8), relayBacked: relayBacked)?.event {
                state.apply(event, at: t0.addingTimeInterval(TimeInterval(offset)))
            }
        }
        return state
    }

    private func classify(_ hooks: AgentHookActivityState?, unknown: Bool = false) -> (AgentActivity, ResumeSafetyAssessment) {
        let evidence = AgentActivityEvidence(registryState: .idle, registryHasHookLifecycleState: true,
                                             registryLastActivityAt: t0, hooks: hooks, foregroundCommandUnknown: unknown)
        let result = AgentActivityClassifier.classify(evidence.signals)
        return (result.activity, result.safety)
    }

    @Test("a compaction or resume SessionStart keeps the running turn; startup and clear reset")
    func sessionStartSource() {
        let running: [(String, String)] = [
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"make"}}"#),
        ]
        for source in ["compact", "resume", ""] {
            let kept = fold(running + [("session-start", #"{"source":"\#(source)"}"#)])
            #expect(kept.turnActive, "\(source)")
            #expect(kept.openTool?.name == "Bash", "\(source)")
        }
        for source in ["startup", "clear"] {
            let reset = fold(running + [("session-start", #"{"source":"\#(source)"}"#)])
            #expect(!reset.turnActive, "\(source)")
            #expect(reset.openTool == nil, "\(source)")
        }
    }

    @Test("an unavailable process census is never safe")
    func processUnknown() {
        let idle = fold([("prompt-submit", #"{}"#), ("stop", #"{}"#)])
        let (activity, safety) = classify(idle, unknown: true)
        #expect(activity.kind == .idle)
        #expect(safety == ResumeSafetyAssessment(safety: .care, reasons: [.idle, .processUnknown]))
        #expect(classify(idle).1.safety == .safe)
        let tool = fold([("prompt-submit", #"{}"#), ("pre-tool-use", #"{"tool_name":"Bash","tool_input":{"command":"x"}}"#)])
        #expect(classify(tool, unknown: true).1 == ResumeSafetyAssessment(safety: .risky, reasons: [.foregroundCommand]))
    }

    @Test("an idle prompt ends the turn and closes calls that never reported back")
    func idlePromptEndsTurn() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"make"}}"#),
            ("notification", #"{"notification_type":"idle_prompt"}"#),
        ])
        #expect(!hooks.turnActive)
        #expect(hooks.openTool == nil)
        #expect(classify(hooks).0.kind == .awaitingInput)
        let question = fold([
            ("pre-tool-use", #"{"tool_name":"AskUserQuestion","tool_input":{}}"#),
            ("notification", #"{"notification_type":"idle_prompt"}"#),
        ])
        #expect(question.pendingQuestion)
    }

    @Test("a later call of another tool closes a pending question")
    func laterToolClosesQuestion() {
        let pre = fold([
            ("pre-tool-use", #"{"tool_name":"ExitPlanMode","tool_input":{}}"#),
            ("pre-tool-use", #"{"tool_name":"Edit","tool_input":{"file_path":"/x"}}"#),
        ])
        #expect(!pre.pendingQuestion)
        let post = fold([
            ("pre-tool-use", #"{"tool_name":"AskUserQuestion","tool_input":{}}"#),
            ("post-tool-use", #"{"tool_name":"Read"}"#),
        ])
        #expect(!post.pendingQuestion)
    }

    @Test("a post without tool_use_id closes the newest same-named call")
    func nilIDClose() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"a","tool_input":{"command":"one"}}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"two"}}"#),
            ("post-tool-use", #"{"tool_name":"Bash"}"#),
        ])
        #expect(hooks.openTool?.command == "one")
        let unmatched = fold([
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"a","tool_input":{"command":"one"}}"#),
            ("post-tool-use", #"{"tool_name":"Bash","tool_use_id":"zzz"}"#),
        ])
        #expect(unmatched.openTool?.command == "one")
    }

    @Test("started_at is the PreToolUse time")
    func startedAt() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Bash","tool_input":{"command":"x"}}"#),
        ])
        #expect(hooks.openTool?.startedAt == t0.addingTimeInterval(1))
        #expect(classify(hooks).0.tool?.startedAt == t0.addingTimeInterval(1))
    }

    @Test("relayed question PreToolUse is ignored; relayed tools still count")
    func relayQuestion() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"AskUserQuestion","tool_input":{}}"#),
        ], relayBacked: true)
        #expect(!hooks.pendingQuestion)
        let tool = fold([("pre-tool-use", #"{"tool_name":"Bash","tool_input":{"command":"x"}}"#)], relayBacked: true)
        #expect(tool.openTool?.name == "Bash")
    }

    @Test("subagent hooks and late posts never reopen a finished turn")
    func subagentAfterStop() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("stop", #"{}"#),
            ("pre-tool-use", #"{"tool_name":"Grep","tool_use_id":"g","agent_id":"sub","tool_input":{"pattern":"x"}}"#),
            ("post-tool-use", #"{"tool_name":"Grep","tool_use_id":"g","agent_id":"sub"}"#),
            ("post-tool-use", #"{"tool_name":"Bash","tool_use_id":"late"}"#),
        ])
        #expect(!hooks.turnActive)
        #expect(!hooks.lastToolFinished)
        #expect(hooks.openTool == nil)
        #expect(classify(hooks).0.kind == .idle)
    }

    @Test("since moves only when the state changes")
    func sinceOnlyOnChange() {
        let hooks = fold([
            ("prompt-submit", #"{}"#),
            ("notification", #"{"notification_type":"permission_prompt"}"#),
            ("post-tool-use", #"{"tool_name":"Bash","tool_use_id":"none"}"#),
        ])
        // The permission notification changes nothing; the post marks the turn between calls.
        #expect(hooks.since == t0.addingTimeInterval(2))
        let quiet = fold([("prompt-submit", #"{}"#), ("notification", #"{"notification_type":"permission_prompt"}"#)])
        #expect(quiet.since == t0)
    }

    @Test("without a seen turn boundary the registry's working state stands")
    func registryBeforeBoundary() {
        let hooks = fold([
            ("pre-tool-use", #"{"tool_name":"Bash","tool_use_id":"b","tool_input":{"command":"x"}}"#),
            ("post-tool-use", #"{"tool_name":"Bash","tool_use_id":"b"}"#),
        ])
        let evidence = AgentActivityEvidence(registryState: .working(since: t0), registryHasHookLifecycleState: true,
                                             registryLastActivityAt: t0, hooks: hooks)
        #expect(AgentActivityClassifier.classify(evidence.signals).activity.kind == .thinking)
    }

    @Test("process filtering starts at the turn start, else at the last idle point")
    func processesNotBefore() {
        let idle = fold([("prompt-submit", #"{}"#), ("stop", #"{}"#)])
        #expect(idle.processesNotBefore == t0.addingTimeInterval(1))
        let running = fold([("prompt-submit", #"{}"#), ("stop", #"{}"#), ("prompt-submit", #"{}"#)])
        #expect(running.processesNotBefore == t0.addingTimeInterval(2))
    }
}

@Suite("Agent foreground command")
struct AgentForegroundCommandTests {
    private typealias P = AgentForegroundCommand.Process

    private func census(_ processes: [P]) -> [Int: P] {
        Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    }

    @Test("an MCP server child is not a foreground command; a shell child is")
    func shellChildOnly() {
        let processes = census([
            P(pid: 10, parentPID: 1, name: "claude", isTerminalForeground: true),
            P(pid: 11, parentPID: 10, name: "node", isTerminalForeground: true),
        ])
        #expect(AgentForegroundCommand.commandPID(agentPID: 10, processes: processes) == nil)
        let running = census([
            P(pid: 10, parentPID: 1, name: "claude", isTerminalForeground: true),
            P(pid: 11, parentPID: 10, name: "node", isTerminalForeground: true),
            P(pid: 12, parentPID: 10, name: "zsh", isTerminalForeground: true),
            P(pid: 13, parentPID: 12, name: "swift-build", isTerminalForeground: true),
        ])
        #expect(AgentForegroundCommand.commandPID(agentPID: 10, processes: running) == 13)
    }

    @Test("background shells and shells older than the turn are ignored")
    func filters() {
        let turn = Date(timeIntervalSince1970: 500)
        let processes = census([
            P(pid: 10, parentPID: 1, name: "claude", isTerminalForeground: true),
            P(pid: 12, parentPID: 10, name: "zsh", isTerminalForeground: false),
            P(pid: 14, parentPID: 10, name: "bash", isTerminalForeground: true, startedAt: Date(timeIntervalSince1970: 100)),
        ])
        #expect(AgentForegroundCommand.commandPID(agentPID: 10, processes: processes, notBefore: turn) == nil)
        #expect(AgentForegroundCommand.commandPID(agentPID: 10, processes: processes) == 14)
    }

    @Test("describe shows a shell's script and truncates")
    func describe() {
        #expect(AgentForegroundCommand.describe(arguments: ["/bin/zsh", "-c", "-l", "npm test"]) == "npm test")
        #expect(AgentForegroundCommand.describe(arguments: ["/usr/bin/make", "-j8", "all"]) == "make -j8 all")
        #expect(AgentForegroundCommand.describe(arguments: []) == nil)
        let long = AgentForegroundCommand.describe(arguments: ["x", String(repeating: "a", count: 300)])
        #expect(long?.count == AgentForegroundCommand.maximumLength)
    }
}

@Suite("Agent pane placement")
struct AgentPanePlacementTests {
    @Test("only local panes stop with the app")
    func survivesAppRelaunch() {
        #expect(!AgentPanePlacement.local.survivesAppRelaunch)
        #expect(AgentPanePlacement.ssh(host: "box").survivesAppRelaunch)
        #expect(AgentPanePlacement.cloud.survivesAppRelaunch)
        #expect(AgentPanePlacement.ssh(host: "box").kind == "ssh")
        #expect(AgentPanePlacement.ssh(host: "box").host == "box")
        #expect(AgentPanePlacement.cloud.host == nil)
    }

    @Test("the turn start is kept until Stop")
    func turnStart() {
        var state = AgentHookActivityState()
        let start = Date(timeIntervalSince1970: 10)
        state.apply(.promptSubmit, at: start)
        state.apply(.preToolUse(id: nil, tool: .init(name: "Bash"), subagent: false), at: start.addingTimeInterval(5))
        #expect(state.turnStartedAt == start)
        state.apply(.stop(backgroundWork: false), at: start.addingTimeInterval(9))
        #expect(state.turnStartedAt == nil)
    }
}
