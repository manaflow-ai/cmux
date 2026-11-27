import CmuxMobileRPC
import Testing
@testable import CmuxMobileShell

@Suite
struct MobileShellMacAvailabilityFailureClassifierTests {
    @Test
    func cleanupBlockedRouteIsUnavailableWhileAccountMismatchIsReachable() {
        let classifier = MobileShellMacAvailabilityFailureClassifier()

        #expect(classifier.isAvailabilityFailure(
            MobileShellConnectionError.routeCleanupBlocked
        ))
        #expect(!classifier.isAvailabilityFailure(
            MobileShellConnectionError.accountMismatch("different account")
        ))
    }
}
