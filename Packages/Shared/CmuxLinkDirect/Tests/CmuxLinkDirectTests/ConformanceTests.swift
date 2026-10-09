import CmuxLink
import CmuxLinkTesting
import Testing

/// The A3 carrier conformance suite on real localhost sockets.
@Suite("Direct carrier conformance", .serialized)
struct ConformanceTests {
    @Test("localhost", arguments: ConformanceCase.allCases)
    func localhost(_ testCase: ConformanceCase) async throws {
        let outcome = try await LinkConformanceSuite(harness: DirectHarness()).run(testCase)
        #expect(outcome == .passed)
    }
}
