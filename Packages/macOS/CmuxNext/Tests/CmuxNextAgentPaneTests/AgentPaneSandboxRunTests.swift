import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat's Sandboxed send (`sandbox.run`, hq#3367): only a new chat with a fresh gesture
/// reaches the App's runner, and its reply carries the receipt or the runner's typed failure. The
/// core cases; the rest are in the tests PR stacked on this one.
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
