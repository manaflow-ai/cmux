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
    @MainActor private final class Seen { var startAllowed: Bool? }

    private static func pane(_ runs: Runs, sessionId: String? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: sessionId)
        model.onSandboxRun = { task, _, _, _ in
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

    @Test func onlyTheReceiptFieldsTheChatShowsCrossToThePage() async {
        let receipt: [String: Any] = [
            "schema": "cmux.run.receipt/v1", "runId": "run-7", "environment": "sandboxed", "status": "succeeded",
            "image": ["id": "img-1", "version": "3"], "exitCode": 0, "signal": NSNull(), "timedOut": false,
            "reply": "done", "error": "boot failed on vm-abc", "cleanup": "destroyed",
            "artifacts": [["name": "a.md", "mediaType": "text/markdown", "sizeBytes": 3, "digest": "sha256:x"]],
            "timings": ["createdAt": "t", "totalMs": 9, "bootMs": 2, "runMs": 7],
            "cost": ["vmSeconds": 9, "vcpus": 2, "memoryMb": 512, "estimateUsd": 0.01],
        ]
        let reply = await AgentPaneReply.sandbox({ ["run": ["id": "run-7"], "receipt": receipt] }) { _ in "x" }
        let page = (reply["value"] as? [String: Any])?["receipt"] as? [String: Any]
        #expect(page?.keys.sorted() == ["artifacts", "cleanup", "cost", "exitCode", "reply", "status", "timedOut", "timings"])
        #expect((page?["artifacts"] as? [[String: Any]])?.first?.keys.sorted() == ["name", "sizeBytes"])
        #expect((page?["timings"] as? [String: Any])?.keys.sorted() == ["bootMs", "totalMs"])
        #expect((page?["cost"] as? [String: Any])?.keys.sorted() == ["estimateUsd", "vmSeconds"])
        // As JSON decodes it: a 0 exit code stays a number, `false` stays a boolean.
        let decoded = try? JSONSerialization.jsonObject(with: Data(#"{"exitCode":0,"timedOut":false,"status":"failed"}"#.utf8))
        let fromJSON = AgentPaneReply.pageReceipt(decoded as? [String: Any] ?? [:])
        #expect((fromJSON["exitCode"] as? NSNumber)?.intValue == 0)
        #expect(fromJSON["timedOut"] as? Bool == false)
    }

    @Test func onlyTheRunAPIsDocumentedRequestRefusalsAreDefinite() {
        // A Run API with no sandboxed Runs ("not enabled yet", the App's mapping of its refusals of a
        // sandboxed body) frees the tab too.
        #expect(AgentPaneSandboxRuns.isDefiniteRefusal(AgentPaneReply.failure(code: "run_sandbox_unavailable", message: "x")))
        #expect(AgentPaneReply.pageCode("run_sandbox_unavailable") == "run_sandbox_unavailable")
        for code in ["run_task_required", "run_image_invalid", "run_invalid_request"] {
            #expect(AgentPaneSandboxRuns.isDefiniteRefusal(AgentPaneReply.failure(code: code, message: code)))
            #expect(AgentPaneReply.pageCode(code) == code)
        }
        // Shaped like one but undocumented, or could hold a handle: no proof nothing ran.
        for code in ["run_model_required", "run_task_invalid", "run_vm_deadbeef_invalid", "provider_vm_abc_invalid", "run_task_failed"] {
            #expect(!AgentPaneSandboxRuns.isDefiniteRefusal(AgentPaneReply.failure(code: code, message: code)))
            #expect(AgentPaneReply.pageCode(code) == "unavailable")
        }
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
        _ = replacements.sending(method: "session/prompt", connection: 0)
        _ = replacements.sending(method: nil, connection: 0)
        #expect(!replacements.holds)
        _ = replacements.sending(method: "_acpmux/attach", connection: 0)
        #expect(replacements.holds)
        // The daemon refused it: a definite failed open frees Sandboxed.
        replacements.observe(["id": 7, "error": ["code": -32000]], replyTo: "_acpmux/attach", connection: 0)
        #expect(!replacements.holds)
        // An open that succeeded holds until the chat is adopted (the pane is no new chat then).
        _ = replacements.sending(method: "session/new", connection: 0)
        replacements.observe(["id": 8, "result": [:]], replyTo: "session/new", connection: 0)
        #expect(replacements.holds)
        // An event that merely names a method is no answer.
        let other = AcpmuxPaneReplacements()
        _ = other.sending(method: "session/load", connection: 0)
        other.observe(["method": "_acpmux/event", "params": [:]], replyTo: nil, connection: 0)
        #expect(other.holds)
        // A start sent on a socket that then closed keeps its hold across the reconnect: the new
        // connection's answers don't end it; only its own (late) answer does.
        let reconnected = AcpmuxPaneReplacements()
        _ = reconnected.sending(method: "session/new", connection: 1)
        reconnected.observe(["id": 9, "error": ["code": -32000]], replyTo: "session/new", connection: 2)
        #expect(reconnected.holds)
        reconnected.observe(["id": 3, "error": ["code": -32000]], replyTo: "session/new", connection: 1)
        #expect(!reconnected.holds)
        // One counted but never sent stops counting.
        let unsent = AcpmuxPaneReplacements()
        _ = unsent.sending(method: "session/resume", connection: 0)
        unsent.notSent(method: "session/resume", connection: 0)
        #expect(!unsent.holds)
    }

    @Test func noChatStartsOrOpensWhileASandboxedSendRuns() async {
        let replacements = AcpmuxPaneReplacements()
        #expect(replacements.beginSandbox())
        // A second Sandboxed send, and every start or open, is refused until the send ends.
        #expect(!replacements.beginSandbox())
        #expect(!replacements.sending(method: "session/new", connection: 0))
        #expect(!replacements.sending(method: "_acpmux/attach", connection: 0))
        #expect(replacements.sending(method: "session/prompt", connection: 0))
        #expect(!replacements.holds)
        replacements.endSandbox()
        #expect(replacements.sending(method: "session/new", connection: 0))
        // And a start out refuses a Sandboxed send.
        #expect(!replacements.beginSandbox())

        // Through the pane: no start while the App's runner runs, and the gate opens once it answers.
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let seen = Seen()
        model.onSandboxRun = { [replacements = model.transport.replacements] _, _, _, _ in
            seen.startAllowed = replacements.sending(method: "session/new", connection: 9)
            return AgentPaneReply.success(["receipt": ["status": "succeeded"]])
        }
        model.transport.gestures.record()
        _ = await model.respond(to: Self.run("go"))
        #expect(seen.startAllowed == false)
        #expect(model.transport.replacements.sending(method: "session/new", connection: 9))
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
            _ = replacements.sending(method: facts.method, connection: 0)
            #expect(replacements.holds)
        }
    }

    @Test func aStartWhileASandboxedSendRunsIsRefusedBeforeItSpendsAnything() {
        // Checked before the gesture and the start credit (AgentPaneTransport decide): only a start
        // or open, and only while the send runs.
        let replacements = AcpmuxPaneReplacements()
        #expect(!replacements.refuses(method: "session/new"))
        #expect(replacements.beginSandbox())
        for method in ["session/new", "session/load", "session/resume", "_acpmux/attach"] {
            #expect(replacements.refuses(method: method))
        }
        #expect(!replacements.refuses(method: "session/prompt"))
        #expect(!replacements.refuses(method: nil))
        replacements.endSandbox()
        #expect(!replacements.refuses(method: "session/new"))
    }

    @MainActor private final class Window { var closed = false; var incognito = false; var seen: [Bool] = [] }

    @Test func theRunKeepsTheIncognitoStateItsSendWasIssuedWith() async {
        // #31109: the tab closes while the send line drains. The App's read answers "incognito" for a
        // page no tab holds, so a read after the drain would take a normal tab's Run as incognito.
        for incognito in [false, true] {
            let window = Window()
            window.incognito = incognito
            let model = AgentPaneModel(host: NoHost(), sessionId: nil)
            model.sendIsIncognito = {
                defer { window.closed = true } // the tab closes right after the send is issued
                return window.closed || window.incognito
            }
            model.onSandboxRun = { _, _, _, incognito in
                window.seen.append(incognito)
                return AgentPaneReply.success(["receipt": ["status": "succeeded"]])
            }
            model.transport.gestures.record()
            _ = await model.respond(to: Self.run("go"))
            #expect(window.seen == [incognito])
        }
        // A pane the App never told is taken as incognito.
        let untold = AgentPaneModel(host: NoHost(), sessionId: nil)
        let window = Window()
        untold.onSandboxRun = { _, _, _, incognito in
            window.seen.append(incognito)
            return AgentPaneReply.success(["receipt": ["status": "succeeded"]])
        }
        untold.transport.gestures.record()
        _ = await untold.respond(to: Self.run("go"))
        #expect(window.seen == [true])
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

    @Test func anUndocumentedRefusalShapedCodeSpendsTheTab() async {
        // `run_vm_deadbeef_invalid` looks like a request refusal but is no proof nothing ran: the
        // page sees `unavailable`, and a second send could start a second paid Run, so it is refused.
        struct Failed: Error {}
        let reply = await AgentPaneReply.sandbox({ throw Failed() }) { _ in "run_vm_deadbeef_invalid" }
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unavailable")
        let runs = AgentPaneSandboxRuns()
        _ = await runs.run(task: "x", key: "k-1") { reply }
        #expect(runs.refusal == "sandbox_spent")
        // A documented one refused the request before anything was stored: the tab may send again.
        let documented = AgentPaneSandboxRuns()
        _ = await documented.run(task: "x", key: "k-2") { AgentPaneReply.failure(code: "run_image_invalid", message: "x") }
        #expect(documented.refusal == nil)
    }

    @Test func aReloadedPageFindsTheRunningSendAndItsReceipt() async {
        let runs = AgentPaneSandboxRuns()
        let gate = AsyncStream<Void>.makeStream()
        let sent = Task { @MainActor in
            _ = await runs.run(task: "go", key: "k-1") {
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
        // A reloaded page that waits on a send which is then refused before any Run finds none.
        let waited = AgentPaneSandboxRuns()
        let refusalGate = AsyncStream<Void>.makeStream()
        let refusing = Task { @MainActor in
            _ = await waited.run(task: "x", key: "k-4") {
                for await _ in refusalGate.stream { break }
                return AgentPaneReply.failure(code: "run_sandbox_unavailable", message: "x")
            }
        }
        await Task.yield()
        let waiting = Task { @MainActor in (await waited.state(wait: true))["value"] is [String: Any] }
        await Task.yield()
        refusalGate.continuation.yield()
        _ = await refusing.value
        #expect(await waiting.value == false)
        let lost = AgentPaneSandboxRuns()
        _ = await lost.run(task: "x", key: "k-3") { AgentPaneReply.failure(code: "timeout", message: "x") }
        #expect(lost.refusal == "sandbox_spent")
    }
}
