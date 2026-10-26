import Testing
@testable import CmuxWorkspaces

@Suite("SessionSnapshotOmittedPanelContainer")
struct SessionSnapshotOmittedPanelContainerTests {
    /// Log labels are diagnostic tokens that log queries match, so they must not change.
    @Test("Each container has a distinct stable log label")
    func logLabelsAreStable() {
        #expect(SessionSnapshotOmittedPanelContainer.workspace.logLabel == "workspace")
        #expect(SessionSnapshotOmittedPanelContainer.workspaceDock.logLabel == "workspace-dock")
        #expect(SessionSnapshotOmittedPanelContainer.windowDock.logLabel == "window-dock")
    }
}
