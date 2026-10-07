import CmuxLink
import CmuxLinkTesting
import Testing

@Suite("PathSelector")
struct PathSelectorTests {
    let peer = LinkPeer(hostID: "host")

    @Test("waits the preference window for a better path")
    func prefersDirectWithinWindow() async throws {
        let clock = ManualClock()
        let network = LoopbackNetwork(clock: LinkClock(clock))
        await network.setConnectDelay(.direct, .milliseconds(100))
        let selector = PathSelector(
            carriers: [network.carrier(kind: .doRelay, path: .relay), network.carrier(kind: .direct, path: .direct)],
            policy: PathPolicy(preferenceWindow: .milliseconds(150)),
            clock: LinkClock(clock)
        )
        let race = Task { try await selector.race(to: peer) }
        // Direct's connect delay and the preference window are both sleeping.
        await clock.waitForSleepers(2)
        clock.advance(by: .milliseconds(100))
        let transport = try await race.value
        #expect(await transport.path.kind == .direct)
        #expect(await network.liveTransportCount == 1)
    }

    @Test("takes the best success when the window ends")
    func windowExpires() async throws {
        let clock = ManualClock()
        let network = LoopbackNetwork(clock: LinkClock(clock))
        await network.setConnectDelay(.direct, .seconds(5))
        let selector = PathSelector(
            carriers: [network.carrier(kind: .direct, path: .direct), network.carrier(kind: .webrtc, path: .turn, candidatePaths: [.p2p, .turn])],
            policy: PathPolicy(preferenceWindow: .milliseconds(150)),
            clock: LinkClock(clock)
        )
        let race = Task { try await selector.race(to: peer) }
        await clock.waitForSleepers(2)
        clock.advance(by: .milliseconds(150))
        let transport = try await race.value
        #expect(await transport.path == LinkPath(kind: .turn, carrier: .webrtc))
    }

    @Test("takes the first success at once when nothing better is pending")
    func immediateWhenBest() async throws {
        let clock = ManualClock()
        let network = LoopbackNetwork(clock: LinkClock(clock))
        await network.setConnectDelay(.doRelay, .seconds(5))
        let selector = PathSelector(
            carriers: [network.carrier(kind: .direct, path: .direct), network.carrier(kind: .doRelay, path: .relay)],
            clock: LinkClock(clock)
        )
        let transport = try await selector.race(to: peer)
        #expect(await transport.path.kind == .direct)
    }

    @Test("ranks by the path a carrier produced, not the carrier")
    func ranksResultingPath() async throws {
        let network = LoopbackNetwork()
        let selector = PathSelector(carriers: [
            network.carrier(kind: .webrtc, path: .turn, candidatePaths: [.p2p, .turn]),
            network.carrier(kind: .webrtcWireGuard, path: .p2p, candidatePaths: [.p2p, .turn]),
        ])
        let transport = try await selector.race(to: peer)
        #expect(await transport.path == LinkPath(kind: .p2p, carrier: .webrtcWireGuard))
    }

    @Test("all failures are reported")
    func allFail() async throws {
        let network = LoopbackNetwork()
        await network.setRefusing(.direct, true)
        await network.setRefusing(.doRelay, true)
        let selector = PathSelector(carriers: [
            network.carrier(kind: .direct, path: .direct), network.carrier(kind: .doRelay, path: .relay),
        ])
        await #expect {
            _ = try await selector.race(to: peer)
        } throws: { error in
            guard case let LinkError.allCarriersFailed(messages) = error else { return false }
            return messages.count == 2
        }
    }

    @Test("an upgrade race only runs carriers that could beat the threshold")
    func upgradeThreshold() async throws {
        let network = LoopbackNetwork()
        let selector = PathSelector(carriers: [
            network.carrier(kind: .direct, path: .direct), network.carrier(kind: .doRelay, path: .relay),
        ])
        let transport = try await selector.race(to: peer, betterThan: PathPolicy().rank(of: .turn))
        #expect(await transport.path.kind == .direct)
        #expect(await network.connectCount(.doRelay) == 0)
        await network.setPath(.direct, .relay)
        await #expect(throws: LinkError.self) {
            _ = try await selector.race(to: peer, betterThan: PathPolicy().rank(of: .turn))
        }
    }
}
