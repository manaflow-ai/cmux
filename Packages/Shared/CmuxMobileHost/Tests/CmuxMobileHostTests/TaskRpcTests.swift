import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

@Suite("task family over rpc and the uplink")
struct TaskRpcTests {
    func harness(allows: Bool = true, runner: FakeTaskRunner = FakeTaskRunner(),
                 attachments: any MobileTaskAttachmentResolver = UnavailableTaskAttachments()) async throws -> PhoneHarness {
        try await PhoneHarness(taskRunner: runner, allowsTaskDispatch: allows, taskAttachments: attachments)
    }

    func dispatch(_ key: String, _ extra: [String: JSONValue] = [:]) -> OpFrame {
        var params: [String: JSONValue] = ["host": "h_mac1", "agent": "claude", "model": "opus", "effort": "high",
                                           "prompt": "Fix the failing sizing tests", "workspace": "ws_a1"]
        params.merge(extra) { $1 }
        return OpFrame(op: "task.dispatch", params: .object(params), idempotencyKey: key, stream: "task:h_mac1")
    }

    @Test func helloAdvertisesTaskCapsOnlyWhenDispatchIsAllowed() async throws {
        let on = try await harness()
        defer { Task { await on.shutdown() } }
        #expect(on.host.configuration.caps.contains("task.stream"))
        #expect(on.host.configuration.caps.contains("task.dispatch"))
        let off = try await harness(allows: false)
        defer { Task { await off.shutdown() } }
        #expect(off.host.configuration.caps.contains("task.stream"))
        #expect(!off.host.configuration.caps.contains("task.dispatch"))
        let none = try await PhoneHarness()
        defer { Task { await none.shutdown() } }
        #expect(!none.host.configuration.caps.contains("task.stream"))
    }

    @Test func taskStreamSnapshotCarriesAgentsThenStateEvents() async throws {
        let runner = FakeTaskRunner()
        let h = try await harness(runner: runner)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .subscribe(SubscribeFrame(stream: "task:h_mac1")))
        let snapshot = try await PhoneHarness.nextJSON(rpc)
        #expect(snapshot["t"] == "snapshot")
        #expect(snapshot["stream"] == "task:h_mac1")
        #expect(snapshot["seq"] == .int(5000))
        #expect(snapshot["state"]?["agents"]?.arrayCount == 2)
        #expect(snapshot["state"]?["agents"]?.item(1)?["unavailable"] == "Not signed in")
        #expect(snapshot["state"]?["agents"]?.item(0)?["models"]?.item(0)?["default_effort"] == "medium")
        #expect(snapshot["epoch"]?.stringValue?.hasPrefix("ep_5000_") == true)

        try await rpc.send(frame: .op(dispatch("key-task-0001")))
        // The new task is structural: a snapshot at the next seq, then the result.
        var frames: [JSONValue] = []
        while frames.count < 3 { frames.append(try await PhoneHarness.nextJSON(rpc)) }
        let next = try #require(frames.first { $0["t"] == "snapshot" })
        #expect(next["seq"] == .int(5001))
        #expect(next["state"]?["tasks"]?.item(0)?["id"] == "task_k1")
        let result = try #require(frames.first { $0["t"] == "result" })
        #expect(result["value"] == ["task": "task_k1", "workspace": "ws_a1", "tab": "tab_a1"])
        #expect(result["revision"] == "5001")
        let settled = try #require(frames.first { $0["t"] == "request-settled" })
        #expect(settled["stream"] == "task:h_mac1")
        #expect(settled["ok"] == true)

        await runner.setState("task_k1", .needsInput)
        let event = try await PhoneHarness.nextJSON(rpc)
        #expect(event["t"] == "event")
        #expect(event["op"] == "task.state.set")
        #expect(event["seq"] == .int(5002))
        #expect(event["params"]?["state"] == "needs_input")
        #expect(event["params"]?["tab"] == "tab_a1")
    }

    @Test func dispatchReachesTheRunnerOnceWithThePromptAsData() async throws {
        let runner = FakeTaskRunner()
        let h = try await harness(runner: runner)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        let op = dispatch("key-task-0002", ["prompt": "echo $HOME; `id`"])
        try await rpc.send(frame: .op(op))
        #expect(try await PhoneHarness.nextJSON(rpc)["t"] == "result")
        _ = try await PhoneHarness.nextJSON(rpc)
        try await rpc.send(frame: .op(op))
        let replay = try await PhoneHarness.nextJSON(rpc)
        #expect(replay["replayed"] == true)
        #expect(await runner.dispatchCount == 1)
        #expect(await runner.lastDispatch?.prompt == "echo $HOME; `id`")
        #expect(await runner.lastContext == MobileOpContext(install: PhoneHarness.install, idempotencyKey: "key-task-0002"))
    }

    @Test func refusalsNeverReachTheRunner() async throws {
        let runner = FakeTaskRunner()
        let h = try await harness(allows: false, runner: runner)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .op(dispatch("key-task-0003")))
        let reject = try await PhoneHarness.nextJSON(rpc)
        #expect(reject["t"] == "reject")
        #expect(reject["details"]?["reason"] == "spawn_unverified")
        let settled = try await PhoneHarness.nextJSON(rpc)
        #expect(settled["stream"] == "task:h_mac1")
        #expect(settled["ok"] == false)
        #expect(await runner.dispatchCount == 0)
    }

    @Test func attachmentsResolveOnlyForTheUploadingInstall() async throws {
        let runner = FakeTaskRunner()
        let mine = FakeAttachments(install: PhoneHarness.install, uploads: ["up_mine1": "/Users/me/Downloads/cmux-phone/a.png"])
        let h = try await harness(runner: runner, attachments: mine)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .op(dispatch("key-task-0004", ["attachments": ["up_other1"]])))
        let reject = try await PhoneHarness.nextJSON(rpc)
        #expect(reject["code"] == "task.attachment_missing")
        _ = try await PhoneHarness.nextJSON(rpc)
        try await rpc.send(frame: .op(dispatch("key-task-0005", ["attachments": ["up_mine1"]])))
        var result: JSONValue?
        while result == nil {
            let frame = try await PhoneHarness.nextJSON(rpc)
            if frame["t"] == "result" { result = frame }
        }
        #expect(await runner.lastDispatch?.attachments == [MobileTaskAttachment(upload: "up_mine1",
                                                                                 path: "/Users/me/Downloads/cmux-phone/a.png")])
    }

    @Test func taskListReadAndCancel() async throws {
        let runner = FakeTaskRunner()
        let h = try await harness(runner: runner)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .op(dispatch("key-task-0006")))
        _ = try await PhoneHarness.nextJSON(rpc)
        _ = try await PhoneHarness.nextJSON(rpc)
        try await rpc.send(frame: .read(ReadFrame(id: 7, op: "task.list", params: ["host": "h_mac1", "limit": 5])))
        let list = try await PhoneHarness.nextJSON(rpc)
        #expect(list["t"] == "read.result")
        #expect(list["value"]?["tasks"]?.item(0)?["agent"] == "claude")
        try await rpc.send(frame: .op(OpFrame(op: "task.cancel", params: ["task": "task_k1"], idempotencyKey: "key-cancel-01")))
        #expect(try await PhoneHarness.nextJSON(rpc)["t"] == "result")
        #expect(await runner.cancelled == ["task_k1"])
    }

    @Test func uplinkMirrorsTheTaskStreamAndAnswersForwardedDispatchAndList() async throws {
        let runner = FakeTaskRunner()
        let h = try await harness(runner: runner)
        defer { Task { await h.shutdown() } }
        let socket = FakeControlSocket()
        let uplink = HostControlUplink(socket: socket, host: h.host, install: "in_mac1", appVersion: "1.0")
        let run = Task { try await uplink.run() }
        defer { run.cancel() }
        _ = try await socket.next()
        socket.deliver(try MobileFrame.helloOK(HelloOKFrame(version: 1, caps: ["read"], serverTime: 0, maxFrame: 131_072)).jsonValue)
        let caps = try await socket.next()
        #expect(caps["params"]?["caps"]?.items.contains("task.dispatch") == true)
        _ = try await socket.next()

        socket.deliver(["t": "snapshot.request", "stream": "task:h_mac1"])
        let snapshot = try await socket.next()
        #expect(snapshot["stream"] == "task:h_mac1")
        #expect(snapshot["seq"] == .int(5000))

        socket.deliver([
            "t": "op", "op": "task.dispatch", "idempotency_key": "key-task-0007", "stream": "task:h_mac1",
            "params": ["agent": "claude", "prompt": "go", "workspace": "ws_a1"], "from": "in_phone1",
            "actor": ["identity": "in_phone1", "install": "in_phone1", "user": "u_alice", "kind": "install"],
        ])
        var answers: [JSONValue] = []
        var mirrored: JSONValue?
        // The mirrored snapshot and the answer travel independently.
        while answers.count < 2 || mirrored == nil {
            let frame = try await socket.next()
            if frame["t"] == "snapshot" { mirrored = frame; continue }
            answers.append(frame)
        }
        #expect(mirrored?["seq"] == .int(5001))
        #expect(answers[0]["t"] == "result")
        #expect(answers[0]["to"] == "in_phone1")
        #expect(answers[1]["stream"] == "task:h_mac1")

        socket.deliver(["t": "read", "id": 4, "op": "task.list", "params": ["host": "h_mac1"]])
        let read = try await socket.next()
        #expect(read["t"] == "read.result")
        #expect(read["id"] == .int(4))
        #expect(read["value"]?["tasks"]?.arrayCount == 1)
    }
}

extension JSONValue {
    func item(_ index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    var items: [JSONValue] {
        guard case .array(let items) = self else { return [] }
        return items
    }
}
