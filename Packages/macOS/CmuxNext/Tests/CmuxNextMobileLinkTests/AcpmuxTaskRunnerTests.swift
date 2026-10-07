import CmuxMobileHost
import CmuxMobileWire
@testable import CmuxNextMobileLink
import Foundation
import Testing

/// A scripted acpmux: answers by method, records every call, can hold the
/// prompt turn open, and pushes daemon messages.
actor FakeAcpmux: AcpmuxRPC {
    private(set) var calls: [(method: String, params: JSONValue)] = []
    private(set) var notifications: [(method: String, params: JSONValue)] = []
    private var sinks: [AsyncStream<AcpmuxMessage>.Continuation] = []
    private var prompt: CheckedContinuation<JSONValue, any Error>?
    var newSession: JSONValue = ["sessionId": "sess_1", "configOptions": [["id": "effort", "category": "thought_level"]]]

    func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        calls.append((method, params))
        switch method {
        case "_acpmux/harnesses":
            return ["harnesses": ["claude": ["displayName": "Claude Code"], "codex": ["unavailable": "Not signed in"],
                                  "shell": [:]],
                    "defaultHarness": "codex"]
        case "_acpmux/models":
            return ["harnesses": [
                ["harness": "claude", "models": [["id": "opus", "name": "Opus"], ["id": "old", "name": "Old", "unavailable": "gone"]]],
                ["harness": "codex", "models": [["id": "default", "name": "default"]]],
                ["harness": "mini/claude", "peer": "mini", "models": []],
            ]]
        case "session/new": return newSession
        case "session/prompt":
            return try await withCheckedThrowingContinuation { prompt = $0 }
        default: return .object([:])
        }
    }

    func notify(_ method: String, params: JSONValue) async throws { notifications.append((method, params)) }

    func messages() -> AsyncStream<AcpmuxMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: AcpmuxMessage.self)
        sinks.append(continuation)
        return stream
    }

    func close() { sinks.forEach { $0.finish() } }

    func push(_ message: AcpmuxMessage) { sinks.forEach { $0.yield(message) } }

    func endTurn(_ reply: JSONValue) {
        prompt?.resume(returning: reply)
        prompt = nil
    }

    var promptOpen: Bool { prompt != nil }
}

actor FakeTaskWorkspaces: MobileTaskWorkspaces {
    private(set) var created: [String] = []
    private(set) var tabs: [(workspace: String, session: String, harness: String)] = []

    func createWorkspace(idempotencyKey: String) async throws -> String {
        created.append(idempotencyKey)
        return "ws_new"
    }

    func directory(of workspace: String) async throws -> String { "/Users/me/src/\(workspace)" }

    func openAgentTab(workspace: String, session: String, harness: String, idempotencyKey: String) async throws -> String {
        tabs.append((workspace, session, harness))
        return "tab_agent"
    }
}

@Suite("acpmux task runner")
struct AcpmuxTaskRunnerTests {
    let context = MobileOpContext(install: "in_phone1", idempotencyKey: "key-dispatch-1")

    func until(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<2000 where !(await condition()) { await Task.yield() }
    }

    @Test func theCatalogOffersThisMacsACPHarnessesWithTheirAvailability() async throws {
        let acpmux = FakeAcpmux()
        let runner = AcpmuxMobileTaskRunner(hostID: "host_m1", workspaces: FakeTaskWorkspaces()) { acpmux }
        let agents = try await runner.agents()
        #expect(agents.map(\.id) == ["codex", "claude"])
        #expect(agents[0].unavailable == "Not signed in")
        #expect(agents[1].name == "Claude Code")
        #expect(agents[1].models.map(\.id) == ["opus"])
        #expect(agents[1].defaultModel == "opus")
    }

    @Test func aDispatchStartsTheSessionInTheWorkspaceDirectoryAndSendsThePromptAsData() async throws {
        let acpmux = FakeAcpmux(), workspaces = FakeTaskWorkspaces()
        let runner = AcpmuxMobileTaskRunner(hostID: "host_m1", workspaces: workspaces) { acpmux }
        let changes = await runner.changes()
        let request = MobileTaskDispatch(agent: "claude", model: "opus", effort: "high", prompt: "fix the bug\nplease",
                                         attachments: [MobileTaskAttachment(upload: "up_1", path: "/tmp/shot.png")])
        let result = try await runner.dispatch(request, context: context)
        #expect(result.workspace == "ws_new" && result.tab == "tab_agent" && result.task.hasPrefix("task_"))
        #expect(await workspaces.created == ["mobile-task-ws-key-dispatch-1"])
        let calls = await acpmux.calls
        let new = try #require(calls.first { $0.method == "session/new" })
        #expect(new.params["cwd"] == "/Users/me/src/ws_new")
        #expect(new.params["_meta"]?["harness"] == "claude")
        #expect(calls.contains { $0.method == "session/set_model" && $0.params["modelId"] == "opus" })
        #expect(calls.contains { $0.method == "session/set_config_option" && $0.params["configId"] == "effort"
            && $0.params["value"] == "high" })
        await until { await acpmux.promptOpen }
        let prompt = try #require(await acpmux.calls.first { $0.method == "session/prompt" })
        #expect(prompt.params["prompt"] == [["type": "text", "text": "fix the bug\nplease"],
                                            ["type": "resource_link", "uri": "file:///tmp/shot.png", "name": "shot.png"]])
        var task = try #require(try await runner.tasks().first)
        #expect(task.state == .running && task.title == "fix the bug" && task.tab == "tab_agent")

        await acpmux.push(AcpmuxMessage(method: "session/request_permission", params: ["sessionId": "sess_1"], isRequest: true))
        await until { (try? await runner.tasks().first?.state) == .needsInput }
        await acpmux.push(AcpmuxMessage(method: "session/update", params: ["sessionId": "sess_1"], isRequest: false))
        await until { (try? await runner.tasks().first?.state) == .running }
        await acpmux.endTurn(["stopReason": "end_turn"])
        await until { (try? await runner.tasks().first?.state) == .done }
        task = try #require(try await runner.tasks().first)
        #expect(task.state == .done)
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)

        try await runner.cancel(task: task.id, context: context)
        #expect(await acpmux.notifications.map(\.method) == ["session/cancel"])
        await #expect(throws: MobileDaemonError.self) { try await runner.cancel(task: "task_nope", context: context) }
        await runner.close()
    }

    @Test func aSessionThatDoesNotStartFailsTheTaskAndTheDispatch() async throws {
        let acpmux = FakeAcpmux()
        await acpmux.setNewSession(["error": "no"])
        let runner = AcpmuxMobileTaskRunner(hostID: "host_m1", workspaces: FakeTaskWorkspaces()) { acpmux }
        await #expect(throws: MobileDaemonError.self) {
            _ = try await runner.dispatch(MobileTaskDispatch(agent: "claude", prompt: "hi", workspace: "ws_a"), context: context)
        }
        #expect(try await runner.tasks().first?.state == .failed)
        #expect(AcpmuxMobileTaskRunner.effortOption(in: ["configOptions": [["id": "mode"]]]) == nil)
    }
}

extension FakeAcpmux {
    func setNewSession(_ value: JSONValue) { newSession = value }
}
