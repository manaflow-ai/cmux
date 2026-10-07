import CmuxLink
import CmuxLinkTesting
import Testing

/// The A3 carrier conformance suite on real WebRTC peers over loopback ICE.
@Suite("WebRTC carrier conformance", .serialized)
struct ConformanceTests {
    @Test("loopback ICE", arguments: ConformanceCase.allCases)
    func loopback(_ testCase: ConformanceCase) async throws {
        let outcome = try await LinkConformanceSuite(harness: WebRTCHarness()).run(testCase)
        #expect(outcome == .passed)
    }
}
