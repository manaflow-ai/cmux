#if os(iOS)
import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceActionFailureMessageTests {
    @Test func invalidWorkingDirectoryExplainsRecovery() {
        // Failures render as a toast: bold "Couldn't <action>" title plus the
        // reason as a standalone sentence.
        let title = WorkspaceShellView.workspaceActionFailureTitle(action: .createWorkspace)
        let reason = WorkspaceShellView.workspaceActionFailureReasonText(
            .invalidWorkingDirectory(hostDisplayName: "Test Mac")
        )

        #expect(title == "Couldn't create workspace")
        #expect(
            reason == "The working directory isn't available on your Mac; choose another directory."
        )
    }
}
#endif
