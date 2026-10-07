import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

/// The Mac's own reads on its host socket and the handshake as `HostDO`
/// really sends it (`welcome` first, b1-control-do.md 2).
@Suite("HostDO uplink reads")
struct UplinkReadTests {
    /// Runs an uplink through its handshake, with `welcome` before `hello.ok`.
    private func connected(_ h: PhoneHarness) async throws -> (FakeControlSocket, HostControlUplink, Task<Void, any Error>) {
        let socket = FakeControlSocket()
        let uplink = HostControlUplink(socket: socket, host: h.host, install: "in_mac1", appVersion: "1.0")
        let run = Task { try await uplink.run() }
        #expect(try await socket.next()["t"] == "hello")
        socket.deliver(["t": "welcome", "role": "host", "server_time": 1, "streams": []])
        socket.deliver(try MobileFrame.helloOK(HelloOKFrame(version: 1, caps: ["read"], serverTime: 0, maxFrame: 131_072)).jsonValue)
        #expect(try await socket.next()["op"] == "host.caps.set")
        #expect(try await socket.next()["op"] == "host.presence.set")
        return (socket, uplink, run)
    }

    @Test func welcomeBeforeHelloOKDoesNotFailTheHandshake() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (_, _, run) = try await connected(h)
        run.cancel()
    }

    @Test func aReadIsAnsweredByItsResult() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (socket, uplink, run) = try await connected(h)
        defer { run.cancel() }
        let answer = Task { try await uplink.read("signal.turn_credentials", params: ["host": "h_mac1"]) }
        let read = try await socket.next()
        #expect(read["t"] == "read")
        #expect(read["op"] == "signal.turn_credentials")
        #expect(read["params"]?["host"] == "h_mac1")
        let id = try #require(read["id"])
        socket.deliver(["t": "read.result", "id": id, "value": ["ice_servers": [], "expires_at": 5], "revision": "0"])
        let result = try await answer.value
        #expect(result.value["expires_at"] == .int(5))
    }

    @Test func aReadErrorCarriesTheOwnersCode() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (socket, uplink, run) = try await connected(h)
        defer { run.cancel() }
        let answer = Task { try await uplink.read("signal.turn_credentials", params: ["host": "h_mac1"]) }
        let id = try #require(try await socket.next()["id"])
        socket.deliver(["t": "error", "id": id, "code": "signal.turn_unavailable", "message": "no TURN", "retryable": false])
        await #expect(throws: HostControlUplinkError(code: "signal.turn_unavailable", message: "no TURN")) {
            _ = try await answer.value
        }
    }

    @Test func aPendingReadFailsWhenTheSocketCloses() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (socket, uplink, run) = try await connected(h)
        let answer = Task { try await uplink.read("signal.turn_credentials") }
        _ = try await socket.next()
        await socket.close()
        try await run.value
        do {
            _ = try await answer.value
            Issue.record("the read should fail")
        } catch let error as HostControlUplinkError {
            #expect(error.code == "owner.unreachable")
        }
        await #expect(throws: HostControlUplinkError.self) { _ = try await uplink.read("signal.turn_credentials") }
    }
}
