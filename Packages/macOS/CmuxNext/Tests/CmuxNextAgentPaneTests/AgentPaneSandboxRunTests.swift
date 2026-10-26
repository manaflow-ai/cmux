import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat's Sandboxed send (`sandbox.run`, hq#3367): only a new chat with a fresh gesture
/// reaches the App's runner, and its reply carries the receipt or the runner's typed failure.
@Suite
@MainActor
struct AgentPaneSandboxRunTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Runs { var tasks: [String] = [] }

    private static func pane(_ runs: Runs, sessionId: String? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: sessionId)
        model.onSandboxRun = { task, _, _ in
            runs.tasks.append(task)
            return AgentPaneReply.success(["receipt": ["status": "succeeded"], "runId": "run-1"])
        }
        return model
    }

    private static func run(_ task: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "sandbox.run", "params": ["task": task, "agent": "claude", "key": UUID().uuidString]])
    }

    @Test func aNewChatsSendWithAGestureRunsTheTask() async {
        let runs = Runs()
        let model = Self.pane(runs)
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.run("list the TODOs"))
        #expect(reply["ok"] as? Bool == true)
        #expect(runs.tasks == ["list the TODOs"])
    }

    @Test func noGestureAStartedChatOrAnEmptyTaskRunsNothing() async {
        let runs = Runs()
        _ = await Self.pane(runs).respond(to: Self.run("no gesture"))
        let started = Self.pane(runs, sessionId: "chat")
        started.transport.gestures.record()
        _ = await started.respond(to: Self.run("started chat"))
        let empty = Self.pane(runs)
        empty.transport.gestures.record()
        _ = await empty.respond(to: Self.run("   "))
        // A chat start or open waits in this pane's send line.
        let starting = Self.pane(runs)
        starting.transport.gestures.record()
        starting.transport.replacements.set(waiting: 1)
        _ = await starting.respond(to: Self.run("starting chat"))
        let noKey = Self.pane(runs)
        noKey.transport.gestures.record()
        _ = await noKey.respond(to: AgentPaneRequest(body: ["method": "sandbox.run", "params": ["task": "no key"]]))
        #expect(runs.tasks.isEmpty)
    }

    @Test func theReplyCarriesTheReceiptOrTheTypedFailure() async {
        let receipt = await AgentPaneReply.sandbox({ ["run": ["id": "run-2"], "receipt": ["status": "failed"]] }) { _ in "x" }
        let value = receipt["value"] as? [String: Any]
        #expect((value?["receipt"] as? [String: Any])?["status"] as? String == "failed")
        // No provider handle crosses to the page.
        #expect(value?["runId"] == nil)
        #expect(value?.keys.sorted() == ["receipt"])

        struct Refused: Error {}
        let refused = await AgentPaneReply.sandbox({ throw Refused() }) { _ in "run_sandbox_unavailable" }
        let error = refused["error"] as? [String: Any]
        #expect(error?["code"] as? String == "run_sandbox_unavailable")
        #expect(error?["userMessage"] as? String == "run_sandbox_unavailable")

        let noReceipt = await AgentPaneReply.sandbox({ ["run": ["id": "run-3"]] }) { _ in "x" }
        #expect((noReceipt["error"] as? [String: Any])?["code"] as? String == "bad_response")
    }

    @Test func aServerCodeThePageDoesNotWordReachesItAsUnavailable() async {
        // A code from the server's body or a header may name a provider handle: never forwarded.
        struct Failed: Error {}
        for code in ["provider_vm_abc123", "http_502", ""] {
            let reply = await AgentPaneReply.sandbox({ throw Failed() }) { _ in code }
            let error = reply["error"] as? [String: Any]
            #expect(error?["code"] as? String == "unavailable")
            #expect(error?["userMessage"] as? String == "unavailable")
        }
    }

    @Test func aStartOrOpenIsCountedByItsParsedMethodUntilItsAnswer() {
        // Counted by the method the transport parsed, so no spelling of the frame evades it.
        let replacements = AcpmuxPaneReplacements()
        replacements.sent(method: "session/prompt", connection: 0)
        replacements.sent(method: nil, connection: 0)
        #expect(!replacements.holds)
        replacements.sent(method: "_acpmux/attach", connection: 0)
        #expect(replacements.holds)
        // The daemon refused it: a definite failed open frees Sandboxed.
        replacements.observe(["id": 7, "error": ["code": -32000]], replyTo: "_acpmux/attach", connection: 0)
        #expect(!replacements.holds)
        // An open that succeeded holds until the chat is adopted (the pane is no new chat then).
        replacements.sent(method: "session/new", connection: 0)
        replacements.observe(["id": 8, "result": [:]], replyTo: "session/new", connection: 0)
        #expect(replacements.holds)
        // An event that merely names a method is no answer.
        let other = AcpmuxPaneReplacements()
        other.sent(method: "session/load", connection: 0)
        other.observe(["method": "_acpmux/event", "params": [:]], replyTo: nil, connection: 0)
        #expect(other.holds)
        // A start sent on a socket that then closed keeps its hold across the reconnect: the new
        // connection's answers don't end it; only its own (late) answer does.
        let reconnected = AcpmuxPaneReplacements()
        reconnected.sent(method: "session/new", connection: 1)
        reconnected.observe(["id": 9, "error": ["code": -32000]], replyTo: "session/new", connection: 2)
        #expect(reconnected.holds)
        reconnected.observe(["id": 3, "error": ["code": -32000]], replyTo: "session/new", connection: 1)
        #expect(!reconnected.holds)
    }

    @Test func theHandshakeTellsThePageThisAppAnswersSandboxState() throws {
        // Without it the page never reads the tab's send, so it never offers Sandboxed.
        let data = try JSONEncoder().encode(AgentPaneHandshake(transport: .acpmuxBridge))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["sandboxState"] as? Bool == true)
    }

    @Test func anEscapedMethodNameIsCountedByItsDecodedName() {
        // The transport decodes the frame before it counts it: an escaped `/` is still a start.
        let snapshot = AgentPaneTransport.Snapshot(isFirst: false, sessions: AcpmuxPaneSessions(), options: AcpmuxPermissionOptions())
        for spelling in [#"session\/new"#, #"session\u002fnew"#] {
            let text = #"{"jsonrpc":"2.0","id":2,"method":"\#(spelling)","params":{"cwd":"/tmp","mcpServers":[]}}"#
            guard case .frame(let facts, _) = AgentPaneTransport.checkOne(text, snapshot) else {
                Issue.record("refused \(text)")
                continue
            }
            #expect(facts.method == "session/new")
            let replacements = AcpmuxPaneReplacements()
            replacements.sent(method: facts.method, connection: 0)
            #expect(replacements.holds)
        }
    }

    @Test func aSandboxRunWaitsForTheSendLineToDrain() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        #expect(await model.transport.lineDrained(within: .milliseconds(10)))
    }

    @Test func aStartOrOpenThatFailedLeavesSandboxedUsable() async {
        let runs = Runs()
        let model = Self.pane(runs)
        model.transport.replacements.set(waiting: 1)
        model.transport.gestures.record()
        _ = await model.respond(to: Self.run("while it waits"))
        model.transport.replacements.observe(["id": 1, "error": ["code": -32000]], replyTo: "_acpmux/attach", connection: 0)
        model.transport.gestures.record()
        _ = await model.respond(to: Self.run("after it failed"))
        #expect(runs.tasks == ["after it failed"])
    }

    @Test func aReloadedPageFindsTheRunningSendAndItsReceipt() async {
        let runs = AgentPaneSandboxRuns()
        let gate = AsyncStream<Void>.makeStream()
        let sent = Task { @MainActor in
            await runs.run(task: "go", key: "k-1") {
                for await _ in gate.stream { break }
                return AgentPaneReply.success(["receipt": ["status": "succeeded"]])
            }
        }
        await Task.yield()
        let running = await runs.state(wait: false)
        #expect((running["value"] as? [String: Any])?["running"] as? Bool == true)
        #expect(runs.isRunning)
        gate.continuation.yield()
        _ = await sent.value
        let done = await runs.state(wait: true)
        #expect((done["value"] as? [String: Any])?["task"] as? String == "go")
        #expect((done["value"] as? [String: Any])?["key"] as? String == "k-1")
        #expect(!runs.isRunning)
        // Its receipt spent the tab's one paid send; a definite refusal would not have.
        #expect(runs.refusal == "sandbox_spent")
        let refused = AgentPaneSandboxRuns()
        _ = await refused.run(task: "x", key: "k-2") { AgentPaneReply.failure(code: "not_signed_in", message: "x") }
        #expect(refused.refusal == nil)
        // Nothing ran, so a reloaded page finds no send to recover.
        let none = await refused.state(wait: false)
        #expect((none["value"] as? [String: Any]) == nil)
        let lost = AgentPaneSandboxRuns()
        _ = await lost.run(task: "x", key: "k-3") { AgentPaneReply.failure(code: "timeout", message: "x") }
        #expect(lost.refusal == "sandbox_spent")
    }
}
