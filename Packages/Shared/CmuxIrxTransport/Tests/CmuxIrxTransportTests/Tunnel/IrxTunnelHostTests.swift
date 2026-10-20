import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite("tunnel host")
struct IrxTunnelHostTests {
    private func connectLane(_ host: String, _ port: Int) -> FakeTunnelLane {
        FakeTunnelLane(IrxLaneDescriptor(lane: .tcpConnect, host: host, port: port))
    }

    private func makeHost(
        optIn: Bool = false,
        authorized: Bool = true,
        connector: FakeTunnelConnector,
        limits: IrxTunnelHost.Limits = .init(),
        clock: TunnelTestClock = TunnelTestClock()
    ) -> IrxTunnelHost {
        IrxTunnelHost(
            limits: limits,
            connector: connector,
            policy: { IrxTunnelDestinationPolicy(allowsNonLoopbackHosts: optIn) },
            isAuthorized: { authorized },
            listPorts: { [IrxListeningPort(port: 3000, address: "127.0.0.1")] },
            now: { clock.now }
        )
    }

    @Test("loopback connects from the Mac and replies connected")
    func loopbackConnects() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(connector: connector)
        let lane = connectLane("localhost", 3000)
        await host.accept(lane)
        while try await lane.openReply() == nil { await Task.yield() }
        #expect(try await lane.openReply()?.status == .connected)
        #expect(connector.attempts.first?.0 == [.loopbackV4, .loopbackV6])
        #expect(connector.attempts.first?.1 == 3000)
        #expect(await host.activeTunnelCount == 1)
        // The phone half-closes and the Mac side aborts: the relay ends and
        // releases its slot.
        await lane.push(nil)
        connector.channels.first?.cancel()
        await host.drain()
        #expect(await host.activeTunnelCount == 0)
    }

    @Test("metadata is denied without any connect attempt, even opted in")
    func metadataDenied() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(optIn: true, connector: connector)
        let lane = connectLane("169.254.169.254", 80)
        await host.accept(lane)
        await host.drain()
        #expect(try await lane.openReply()?.status == .denied)
        #expect(connector.attempts.isEmpty)
        #expect(await lane.finished)
    }

    @Test("a remote host is denied by default and never resolved")
    func remoteDeniedByDefault() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(connector: connector)
        let lane = connectLane("intranet.example", 80)
        await host.accept(lane)
        await host.drain()
        #expect(try await lane.openReply()?.status == .denied)
        #expect(connector.resolvedNames.isEmpty)
        #expect(connector.attempts.isEmpty)
    }

    @Test("the opt-in resolves on the Mac and connects only to permitted addresses")
    func optInHonored() async throws {
        let connector = FakeTunnelConnector()
        connector.resolution["intranet.example"] = [
            IrxTunnelIPAddress("169.254.169.254")!, IrxTunnelIPAddress("10.1.2.3")!,
        ]
        connector.resolution["metadata.example"] = [IrxTunnelIPAddress("169.254.169.254")!]
        let host = makeHost(optIn: true, connector: connector)

        let allowed = connectLane("intranet.example", 8443)
        await host.accept(allowed)
        while try await allowed.openReply() == nil { await Task.yield() }
        #expect(try await allowed.openReply()?.status == .connected)
        #expect(connector.attempts.first?.0 == [IrxTunnelIPAddress("10.1.2.3")!])

        let rebound = connectLane("metadata.example", 80)
        await host.accept(rebound)
        while try await rebound.openReply() == nil { await Task.yield() }
        #expect(try await rebound.openReply()?.status == .denied)
        #expect(connector.attempts.count == 1)

        let missing = connectLane("nowhere.example", 80)
        await host.accept(missing)
        while try await missing.openReply() == nil { await Task.yield() }
        #expect(try await missing.openReply()?.status == .unresolved)
        await host.stop()
    }

    @Test("connect failures map to their status")
    func connectFailureStatus() async throws {
        let connector = FakeTunnelConnector()
        connector.failure = .refused
        let host = makeHost(connector: connector)
        let lane = connectLane("127.0.0.1", 1)
        await host.accept(lane)
        await host.drain()
        #expect(try await lane.openReply()?.status == .refused)
        #expect(await host.activeTunnelCount == 0)
    }

    @Test("an unauthorized phone cannot open tunnels or list ports")
    func unauthorizedDenied() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(authorized: false, connector: connector)
        let lane = connectLane("localhost", 3000)
        await host.accept(lane)
        let ports = FakeTunnelLane(IrxLaneDescriptor(lane: .listeningPorts))
        await host.accept(ports)
        await host.drain()
        #expect(try await lane.openReply()?.status == .denied)
        #expect(connector.attempts.isEmpty)
        #expect(await ports.aborted)
        #expect(await ports.frames.isEmpty)
    }

    @Test("concurrent tunnels are capped")
    func concurrencyCap() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(connector: connector, limits: .init(maximumConcurrentTunnels: 2))
        var lanes: [FakeTunnelLane] = []
        for _ in 0..<2 {
            let lane = connectLane("localhost", 3000)
            await host.accept(lane)
            while try await lane.openReply() == nil { await Task.yield() }
            lanes.append(lane)
        }
        let third = connectLane("localhost", 3000)
        await host.accept(third)
        while try await third.openReply() == nil { await Task.yield() }
        #expect(try await third.openReply()?.status == .busy)
        #expect(connector.attempts.count == 2)
        await host.stop()
    }

    @Test("the open rate is capped and refills over time")
    func rateCap() async throws {
        let connector = FakeTunnelConnector()
        connector.failure = .refused // no relay left open
        let clock = TunnelTestClock()
        let host = makeHost(connector: connector, limits: .init(openBurst: 3, opensPerSecond: 1), clock: clock)
        var statuses: [IrxTunnelOpenReply.Status] = []
        for _ in 0..<4 {
            let lane = connectLane("localhost", 3000)
            await host.accept(lane)
            await host.drain()
            statuses.append(try await lane.openReply()!.status)
        }
        #expect(statuses == [.refused, .refused, .refused, .busy])
        clock.advance(.seconds(1))
        let later = connectLane("localhost", 3000)
        await host.accept(later)
        await host.drain()
        #expect(try await later.openReply()?.status == .refused)
    }

    @Test("stop aborts every open tunnel and refuses new lanes")
    func stopAbortsTunnels() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(connector: connector)
        let lane = connectLane("localhost", 3000)
        await host.accept(lane)
        while try await lane.openReply() == nil { await Task.yield() }
        await host.stop()
        await lane.waitDone()
        #expect(await lane.aborted)
        #expect(connector.channels.first?.cancelled == true)
        let late = connectLane("localhost", 3000)
        await host.accept(late)
        await late.waitDone()
        #expect(await late.aborted)
    }

    @Test("listening ports reply carries the Mac's ports and policy")
    func listingPorts() async throws {
        let connector = FakeTunnelConnector()
        let host = makeHost(optIn: true, connector: connector)
        let lane = FakeTunnelLane(IrxLaneDescriptor(lane: .listeningPorts))
        await host.accept(lane)
        await host.drain()
        let reply = try await lane.portsReply()
        #expect(reply?.ports == [IrxListeningPort(port: 3000, address: "127.0.0.1")])
        #expect(reply?.allowsNonLoopbackHosts == true)
        #expect(await lane.finished)
    }
}
