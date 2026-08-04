import CmuxMobileRPC
import Testing
@testable import CmuxMobileShell

@Suite
struct SecondaryControlAttemptPolicyTests {
    @Test
    func classifierIsCallableOutsideTheMainActor() async {
        let isTransient = await Task.detached {
            MobileShellComposite.secondaryControlAttemptIsTransient(
                MobileShellConnectionError.requestTimedOut
            )
        }.value

        #expect(isTransient)
    }
}
