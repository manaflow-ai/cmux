import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("rpc channel")
struct RpcTests {
    func subscribed(_ h: PhoneHarness, afterSeq: UInt64? = nil) async throws -> MobileChannel {
        let (rpc, opened) = try await h.open(.rpc, id: 1)
        #expect(opened["t"] == "channel.opened")
        #expect(opened["params"]?["owner"] == .string(PhoneHarness.hostID))
        try await rpc.send(frame: .subscribe(SubscribeFrame(stream: "workspace:h_mac1", afterSeq: afterSeq)))
        return rpc
    }

    @Test func subscribeStartsWithASnapshotThenEvents() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let rpc = try await subscribed(h)
        let snapshot = try await PhoneHarness.nextJSON(rpc)
        #expect(snapshot["t"] == "snapshot")
        #expect(snapshot["seq"] == .int(1000))
        #expect(snapshot["state"]?["workspaces"]?.arrayCount == 1)
        await h.daemon.mutate { $0.workspaces[0].panes[0].tabs[0].status = .running }
        let event = try await PhoneHarness.nextJSON(rpc)
        #expect(event["t"] == "event")
        #expect(event["op"] == "workspace.status.set")
        #expect(event["seq"] == .int(1001))
    }

    @Test func resubscribeAfterSeqReplaysTheTail() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let first = try await subscribed(h)
        _ = try await PhoneHarness.nextJSON(first)
        await h.daemon.mutate { $0.workspaces[0].name = "one" }
        _ = try await PhoneHarness.nextJSON(first)
        await h.daemon.mutate { $0.workspaces[0].name = "two" }
        _ = try await PhoneHarness.nextJSON(first)
        try await first.send(frame: .subscribe(SubscribeFrame(stream: "workspace:h_mac1", afterSeq: 1001)))
        let replayed = try await PhoneHarness.nextJSON(first)
        #expect(replayed["t"] == "event")
        #expect(replayed["seq"] == .int(1002))
        try await first.send(frame: .subscribe(SubscribeFrame(stream: "workspace:h_mac1", afterSeq: 7)))
        #expect(try await PhoneHarness.nextJSON(first)["t"] == "snapshot")
    }

    @Test func renameAnswersResultThenSettledAndDedupesByKey() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        let op = OpFrame(op: "workspace.rename", params: .object(["workspace": "ws_a1", "name": "build"]),
                         idempotencyKey: "key-rename-1")
        try await rpc.send(frame: .op(op))
        let result = try await PhoneHarness.nextJSON(rpc)
        #expect(result["t"] == "result")
        #expect(result["replayed"] == false)
        #expect(result["revision"] == "1001")
        let settled = try await PhoneHarness.nextJSON(rpc)
        #expect(settled["t"] == "request-settled")
        #expect(settled["ok"] == true)
        #expect(settled["sequence"] == .int(1001))
        try await rpc.send(frame: .op(op))
        #expect(try await PhoneHarness.nextJSON(rpc)["replayed"] == true)
        _ = try await PhoneHarness.nextJSON(rpc)
        #expect(await h.daemon.ops == [.renameWorkspace(workspace: "ws_a1", name: "build")])
    }

    @Test func spawnAndCommandOpsAreRejectedWithoutReachingTheDaemon() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .op(OpFrame(op: "workspace.tab.create", params: .object(["workspace": "ws_a1", "kind": "terminal"]),
                                              idempotencyKey: "key-spawn-1")))
        let reject = try await PhoneHarness.nextJSON(rpc)
        #expect(reject["t"] == "reject")
        #expect(reject["code"] == "auth.forbidden")
        #expect(try await PhoneHarness.nextJSON(rpc)["ok"] == false)
        try await rpc.send(frame: .op(OpFrame(op: "workspace.rename",
                                              params: .object(["workspace": "ws_a1", "name": "x", "shell": "/bin/sh"]),
                                              idempotencyKey: "key-cmd-1")))
        #expect(try await PhoneHarness.nextJSON(rpc)["code"] == "auth.forbidden")
        _ = try await PhoneHarness.nextJSON(rpc)
        #expect(await h.daemon.ops.isEmpty)
    }

    @Test func unservedReadsAnswerAnErrorWithTheirID() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .read(ReadFrame(id: 9, op: "files.list", params: .object(["path": "/"]))))
        let error = try await PhoneHarness.nextJSON(rpc)
        #expect(error["t"] == "error")
        #expect(error["id"] == .int(9))
        #expect(error["code"] == "proto.unsupported")
    }
}

extension JSONValue {
    var arrayCount: Int? {
        if case .array(let items) = self { return items.count }
        return nil
    }
}

extension JSONValue: @retroactive ExpressibleByIntegerLiteral, @retroactive ExpressibleByArrayLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
