@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A relaunched window focuses the pane its record saved, not the
/// workspace's first pane.
@MainActor
struct LaunchFocusRestoreTests {
    typealias Pane = FocusTopology.Pane

    private static func topology(workspace: String = "w") -> FocusTopology {
        FocusTopology(workspace: workspace, panes: [
            Pane(id: "a", tabs: [FocusReducerTests.terminal("t1")], selected: "t1"),
            Pane(id: "b", tabs: [FocusReducerTests.terminal("t2")], selected: "t2"),
        ])
    }

    private static func record(focused: String?) -> WindowRecord {
        var record = WindowRecord(id: "win", workspaceKey: WorkspaceKey(rawValue: "w"))
        record.focusedPane = focused
        return record
    }

    /// Regression: launch focused the first pane whatever the record saved.
    @Test func theSavedPaneIsFocusedAtLaunch() {
        let state = WindowState(record: Self.record(focused: "b"))
        state.focus.send(.topology(Self.topology()))
        #expect(state.focus.state.pane == "b")
    }

    @Test func aSavedPaneThatIsGoneFallsBackToTheFirst() {
        let state = WindowState(record: Self.record(focused: "gone"))
        state.focus.send(.topology(Self.topology()))
        #expect(state.focus.state.pane == "a")
    }

    /// The launch window adopts the saved record before the tree arrives.
    @Test func theAdoptedLaunchWindowFocusesTheSavedPane() {
        let state = WindowState(id: "launch")
        state.adopt(Self.record(focused: "b"))
        state.focus.send(.topology(Self.topology()))
        #expect(state.focus.state.pane == "b")
    }

    /// The saved pane belongs to the saved workspace only.
    @Test func anotherWorkspaceStillFocusesItsFirstPane() {
        let state = WindowState(record: Self.record(focused: "b"))
        state.focus.send(.topology(Self.topology(workspace: "other")))
        #expect(state.focus.state.pane == "a")
    }
}
