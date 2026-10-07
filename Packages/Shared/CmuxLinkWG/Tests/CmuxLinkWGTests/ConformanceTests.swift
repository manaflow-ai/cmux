import CmuxLink
import CmuxLinkTesting
import CmuxLinkWGTesting
import Testing

/// The A3 carrier conformance suite over the V2 carrier: real WireGuard on
/// an in-memory underlay, clean and impaired.
@Suite("WebRTC-WG carrier conformance", .serialized)
struct ConformanceTests {
    @Test("clean underlay", arguments: ConformanceCase.allCases)
    func clean(_ testCase: ConformanceCase) async throws {
        let outcome = try await LinkConformanceSuite(harness: WireGuardConformanceHarness()).run(testCase)
        #expect(outcome == .passed)
    }

    @Test("lossy underlay: 3% loss, 1% duplication, jitter reorders", arguments: ConformanceCase.allCases)
    func lossy(_ testCase: ConformanceCase) async throws {
        let conditions = UnderlayConditions(
            latency: .milliseconds(2), jitter: .milliseconds(3), loss: 0.03, duplication: 0.01, seed: 0xB3
        )
        let harness = WireGuardConformanceHarness(name: "webrtc-wg-lossy", conditions: conditions)
        let outcome = try await LinkConformanceSuite(harness: harness).run(testCase)
        #expect(outcome == .passed)
    }
}
