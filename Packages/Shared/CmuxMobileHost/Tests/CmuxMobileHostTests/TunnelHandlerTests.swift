import CmuxLink
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("tcp.forward over the session")
struct TunnelHandlerTests {
    private func harness(_ ports: [TunnelPort], configuration: MobileTunnelConfiguration = .standard) async throws -> PhoneHarness {
        let tunnels = MobileTunnels(configuration: configuration, ports: StaticTunnelPorts(ports))
        let h = try await PhoneHarness(handlers: tunnels.registering())
        try await h.hello()
        return h
    }

    @Test func bytesFlowBothWaysAndHalfCloseEndsTheChannel() async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let h = try await harness([TunnelPort(port: server.port, source: .detected, workspace: "ws_a1")])
        defer { Task { await h.shutdown() } }
        let (channel, opened) = try await h.open(.tcpForward, id: 1, params: ["port": .int(Int64(server.port))])
        #expect(opened["t"] == "channel.opened")
        #expect(opened["params"]?["source"] == "detected")
        let request = Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        try await channel.send(binary: request)
        try await channel.send(binary: Data(), flags: .fin)
        var echoed = Data()
        var sawFin = false
        loop: while true {
            switch try await PhoneHarness.next(channel) {
            case .binary(let data, let flags):
                echoed.append(data)
                if flags.contains(.fin) { sawFin = true }
            case .json(let value):
                #expect(value["t"] == "channel.closed")
                #expect(value["code"] == nil)
                break loop
            case .gap: continue
            case .closed: break loop
            }
        }
        #expect(echoed == request)
        #expect(sawFin)
    }

    @Test func aLargeTransferArrivesIntactUnderSmallCredit() async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let h = try await harness([TunnelPort(port: server.port, source: .allowed)])
        defer { Task { await h.shutdown() } }
        let (channel, _) = try await h.open(.tcpForward, id: 1, params: ["port": .int(Int64(server.port))], budget: 16 * 1024)
        let payload = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let sender = Task {
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 32 * 1024, payload.count)
                try await channel.send(binary: payload[offset..<end])
                offset = end
            }
            try await channel.send(binary: Data(), flags: .fin)
        }
        var echoed = Data()
        loop: while true {
            switch try await PhoneHarness.next(channel) {
            case .binary(let data, _): echoed.append(data)
            case .json, .closed: break loop
            case .gap: continue
            }
        }
        try await sender.value
        #expect(echoed == payload)
    }

    @Test func unadvertisedAndPrivilegedPortsAreRefused() async throws {
        let h = try await harness([TunnelPort(port: 22, source: .allowed), TunnelPort(port: 5173, source: .detected)])
        defer { Task { await h.shutdown() } }
        let (_, privileged) = try await h.open(.tcpForward, id: 1, params: ["port": 22])
        #expect(privileged["t"] == "channel.refused")
        #expect(privileged["code"] == "tunnel.port_not_allowed")
        #expect(privileged["details"]?["reason"] == "privileged")
        let (_, other) = try await h.open(.tcpForward, id: 3, params: ["port": 6000])
        #expect(other["details"]?["reason"] == "not_advertised")
        let (_, bad) = try await h.open(.tcpForward, id: 5, params: ["host": "10.0.0.1", "port": 5173])
        #expect(bad["code"] == "validation.invalid")
    }

    @Test func aPortWithoutAListenerIsRefusedAsRetryable() async throws {
        let port = try EchoServer.closedPort()
        let h = try await harness([TunnelPort(port: port, source: .allowed)])
        defer { Task { await h.shutdown() } }
        let (_, refused) = try await h.open(.tcpForward, id: 1, params: ["port": .int(Int64(port))])
        #expect(refused["code"] == "tunnel.connect_refused")
        #expect(refused["retryable"] == .bool(true))
    }

    @Test func thePerDeviceCapRefusesTheNextStream() async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let h = try await harness([TunnelPort(port: server.port, source: .allowed)],
                                  configuration: MobileTunnelConfiguration(maxStreamsPerDevice: 1))
        defer { Task { await h.shutdown() } }
        let (_, first) = try await h.open(.tcpForward, id: 1, params: ["port": .int(Int64(server.port))])
        #expect(first["t"] == "channel.opened")
        let (_, second) = try await h.open(.tcpForward, id: 3, params: ["port": .int(Int64(server.port))])
        #expect(second["code"] == "tunnel.limit")
    }

    @Test func revocationStopsTheStream() async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let h = try await harness([TunnelPort(port: server.port, source: .allowed)])
        defer { Task { await h.shutdown() } }
        let (channel, _) = try await h.open(.tcpForward, id: 1, params: ["port": .int(Int64(server.port))])
        try await channel.send(binary: Data("ping".utf8))
        guard case .binary = try await PhoneHarness.next(channel) else {
            Issue.record("expected the echo")
            return
        }
        await h.store.revoke(PhoneHarness.install)
        try? await channel.send(binary: Data("after".utf8))
        loop: while true {
            switch try await PhoneHarness.next(channel) {
            case .binary(let data, _): #expect(data != Data("after".utf8))
            case .gap: continue
            case .json(let value):
                #expect(value["code"] == "auth.revoked")
                break loop
            case .closed: break loop
            }
        }
    }

    @Test func tunnelPortsListsOnlyAdmittedPorts() async throws {
        let h = try await harness([TunnelPort(port: 80, source: .allowed), TunnelPort(port: 5173, source: .detected, workspace: "ws_a1")])
        defer { Task { await h.shutdown() } }
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .read(ReadFrame(id: 1, op: "tunnel.ports", params: .object([:]))))
        let reply = try await PhoneHarness.nextJSON(rpc)
        let result = try #require(reply["value"]).decode(as: TunnelPortsResult.self)
        #expect(result.ports == [TunnelPort(port: 5173, source: .detected, workspace: "ws_a1")])
    }
}
