#if os(iOS)
import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceActionFailureMessageTests {
    @Test func invalidWorkingDirectoryExplainsRecovery() {
        let message = WorkspaceShellView.workspaceActionFailureMessage(
            action: .createWorkspace,
            failure: .invalidWorkingDirectory(hostDisplayName: "Test Mac")
        )

        #expect(
            message == "Couldn't create workspace: the working directory isn't available on your Mac; choose another directory."
        )
    }
}
#endif
