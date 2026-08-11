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

        #expect(initializationCount == 1)
        guard case .failed = owner.state else {
            Issue.record("Expected the process-owned renderer failure")
            return
        }
    }

    @MainActor
    @Test("a failed initialization retries through the same process owner")
    func failedInitializationRetriesSuccessfully() throws {
        let runtime = try GhosttyRuntime.shared()
        var initializationCount = 0
        let owner = GhosttyRuntimeOwner {
            initializationCount += 1
            if initializationCount == 1 {
                throw ExpectedFailure()
            }
            return runtime
        }

        guard case .failed = owner.state else {
            Issue.record("Expected the first initialization to fail")
            return
        }

        owner.retry()

        guard case .ready(let recoveredRuntime) = owner.state else {
            Issue.record("Expected retry to install the runtime")
            return
        }
        #expect(recoveredRuntime === runtime)
        #expect(initializationCount == 2)

        owner.retry()
        #expect(initializationCount == 2)
    }
}
#endif
