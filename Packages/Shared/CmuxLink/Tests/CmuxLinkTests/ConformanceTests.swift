import CmuxLink
import CmuxLinkTesting
import Testing

/// The conformance suite against the loopback carrier and the lossy,
/// jittery simulator. Carrier lanes copy this test with their own harness.
@Suite("Carrier conformance")
struct ConformanceTests {
    static let lossy = NetworkConditions(
        latency: .milliseconds(2), jitter: .milliseconds(3), loss: 0.15, seed: 42
    )

    @Test("loopback", arguments: ConformanceCase.allCases)
    func loopback(_ testCase: ConformanceCase) async throws {
        let outcome = try await LinkConformanceSuite(harness: LoopbackHarness()).run(testCase)
        #expect(outcome == .passed)
    }

    @Test("lossy simulator", arguments: ConformanceCase.allCases)
    func simulated(_ testCase: ConformanceCase) async throws {
        let harness = LoopbackHarness(name: "simulated", conditions: Self.lossy, path: .p2p)
        let outcome = try await LinkConformanceSuite(harness: harness).run(testCase)
        #expect(outcome == .passed)
    }

    @Test("a harness without fault hooks skips the fault cases")
    func skipsWithoutHooks() async throws {
        let suite = LinkConformanceSuite(harness: HooklessHarness())
        #expect(try await suite.run(.ordering) == .passed)
        #expect(try await suite.run(.lossRecovery) == .skipped("harness cannot drop transports"))
        #expect(try await suite.run(.priority) == .skipped("harness cannot throttle"))
    }
}

/// A carrier that only connects: no fault injection.
struct HooklessHarness: ConformanceHarness {
    let name = "hookless"

    func makeEndpoints() async throws -> ConformanceEndpoints {
        let network = LoopbackNetwork()
        return ConformanceEndpoints(
            carriers: [network.carrier(kind: .webrtc, path: .p2p)],
            acceptor: network.acceptor
        )
    }
}
