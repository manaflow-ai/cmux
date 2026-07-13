#if os(iOS)
import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerFailureMessageTests {
    @Test func invalidWorkingDirectoryUsesActionableLocalizedDefault() {
        let message = TaskComposerSheet.failureMessage(
            .invalidWorkingDirectory(hostDisplayName: "Test Mac")
        )

        #expect(message == "Choose an existing folder on that Mac.")
    }

    @Test func persistenceFailureExplainsSafeReservationFailure() {
        let message = TaskComposerSheet.failureMessage(
            .persistenceUnavailable(hostDisplayName: "Test Mac")
        )

        #expect(message == "The Mac could not safely reserve this task.")
    }
}
#endif
