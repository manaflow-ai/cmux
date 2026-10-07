import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

/// A scripted HostDO socket.
final class FakeControlSocket: HostControlSocket, Sendable {
    let frames: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    let sent = AsyncQueue<JSONValue>()

    init() {
        (frames, continuation) = AsyncStream<JSONValue>.makeStream()
    }

    func deliver(_ frame: JSONValue) { continuation.yield(frame) }

    func send(_ frame: JSONValue) async throws { await sent.push(frame) }

    func close() async { continuation.finish() }

    func next() async throws -> JSONValue {
        let sent = sent
        return try await within { try #require(await sent.next()) }
    }
}

@Suite("HostDO uplink")
struct UplinkTests {
    @Test func registersMirrorsTheWorkspaceStreamAndAnswersForwardedOps() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let socket = FakeControlSocket()
        let uplink = HostControlUplink(socket: socket, host: h.host, install: "in_mac1", appVersion: "1.0")
        let run = Task { try await uplink.run() }
        defer { run.cancel() }

        let hello = try await socket.next()
        #expect(hello["t"] == "hello")
        #expect(hello["caps"] == ["read", "signal", "presence", "resume"])
        socket.deliver(try MobileFrame.helloOK(HelloOKFrame(version: 1, caps: ["read"], serverTime: 0, maxFrame: 131_072)).jsonValue)
        let caps = try await socket.next()
        #expect(caps["op"] == "host.caps.set")
        #expect(caps["params"]?["host"] == "h_mac1")
        let presence = try await socket.next()
        #expect(presence["op"] == "host.presence.set")
        #expect(presence["params"]?["presence"] == "online")

        socket.deliver(["t": "snapshot.request", "stream": "workspace:h_mac1"])
        let snapshot = try await socket.next()
        #expect(snapshot["t"] == "snapshot")
        #expect(snapshot["seq"] == .int(1000))
        await h.daemon.mutate { $0.workspaces[0].name = "renamed" }
        let event = try await socket.next()
        #expect(event["t"] == "event")
        #expect(event["seq"] == .int(1001))
        #expect(event["op"] == "workspace.upsert")

        socket.deliver([
            "t": "op", "op": "workspace.tab.close", "params": ["tab": "tab_t1"], "idempotency_key": "key-close-1",
            "stream": "workspace:h_mac1", "from": "in_phone1",
            "actor": ["identity": "in_phone1", "install": "in_phone1", "user": "u_alice", "kind": "install"],
        ])
        var answers: [JSONValue] = []
        while answers.count < 2 {
            let frame = try await socket.next()
            if frame["t"] == "event" { continue }
            answers.append(frame)
        }
        #expect(answers[0]["t"] == "result")
        #expect(answers[0]["to"] == "in_phone1")
        #expect(answers[1]["t"] == "request-settled")
        #expect(answers[1]["to"] == "in_phone1")
        #expect(await h.daemon.ops == [.closeTab(tab: "tab_t1")])
    }

    @Test func forwardedOpsFromUnpairedDevicesAreRejected() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let socket = FakeControlSocket()
        let uplink = HostControlUplink(socket: socket, host: h.host, install: "in_mac1", appVersion: "1.0")
        let run = Task { try await uplink.run() }
        defer { run.cancel() }
        _ = try await socket.next()
        socket.deliver(try MobileFrame.helloOK(HelloOKFrame(version: 1, caps: [], serverTime: 0, maxFrame: 131_072)).jsonValue)
        _ = try await socket.next()
        _ = try await socket.next()
        socket.deliver([
            "t": "op", "op": "workspace.rename", "params": ["workspace": "ws_a1", "name": "x"], "idempotency_key": "key-rename-9",
            "from": "in_stranger", "actor": ["identity": "in_stranger", "install": "in_stranger", "user": "u_alice"],
        ])
        let reject = try await socket.next()
        #expect(reject["t"] == "reject")
        #expect(reject["code"] == "auth.forbidden")
        #expect(reject["to"] == "in_stranger")
        #expect(await h.daemon.ops.isEmpty)
    }

    @Test func aRefusedHelloStopsTheUplink() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let socket = FakeControlSocket()
        let uplink = HostControlUplink(socket: socket, host: h.host, install: "in_mac1", appVersion: "1.0")
        let run = Task { try await uplink.run() }
        _ = try await socket.next()
        socket.deliver(["t": "error", "code": "proto.version_unsupported", "message": "no"])
        await #expect(throws: HostControlUplinkError.self) { try await run.value }
    }
}
