#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@MainActor
struct CloudTabStreamVisibilityTests {
    @Test(arguments: [true, false])
    func cloudDoesNotKeepTheMacSimulatorStreamVisible(compact: Bool) {
        #expect(WorkspaceShellView.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: .cloud,
            searchScope: .workspaces,
            usesCompactStack: compact,
            selectedWorkspaceID: "workspace",
            compactNavigationPath: ["workspace"],
            notificationNavigationPath: [],
            workspaceSearchNavigationPath: [],
            notificationSearchNavigationPath: []
        ) == nil)
    }
}
#endif
