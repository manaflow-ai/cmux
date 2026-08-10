#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@Suite("Ghostty runtime ownership")
struct GhosttyRuntimeOwnerTests {
    private struct ExpectedFailure: Error {}

    @MainActor
    @Test("initialization runs once when the owner is created")
    func initializationRunsOnce() {
        var initializationCount = 0
        let owner = GhosttyRuntimeOwner {
            initializationCount += 1
            throw ExpectedFailure()
        }

        _ = owner.result
        _ = owner.result

        #expect(initializationCount == 1)
        guard case .failure = owner.result else {
            Issue.record("Expected the captured renderer failure")
            return
        }
    }
}
#endif
