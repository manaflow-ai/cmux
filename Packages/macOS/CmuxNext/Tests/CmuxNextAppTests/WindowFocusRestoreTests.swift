@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing
import CmuxNextFocus

/// A relaunch returns each workspace of a window to the pane that was
/// focused in it, as classic restores each workspace's focused panel: the
/// window record the daemon keeps in its personal projection carries them.
@MainActor
struct WindowFocusRestoreTests {
    @Test func aRelaunchedWindowReturnsEachWorkspaceToItsFocusedPane() throws {
        let saved = #"""
        {"id":"w1","workspace_key":"ws-a","focused_pane":"a2","focused_panes":{"ws-a":"a2","ws-b":"b2"}}
        """#
        // Through the projection: what the app wrote, the next launch reads.
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: Data(saved.utf8))
        let record = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(decoded))
        let state = WindowState(record: record)

        state.focus.send(.topology(Self.topology("ws-a", panes: ["a1", "a2"])))
        #expect(state.focus.state.pane == "a2")
        state.workspaceID = "ws-b"
        state.focus.send(.topology(Self.topology("ws-b", panes: ["b1", "b2"])))
        #expect(state.focus.state.pane == "b2", "the focused pane of a workspace the window did not show was lost")
    }

    private static func topology(_ workspace: String, panes: [String]) -> FocusTopology {
        FocusTopology(workspace: workspace, panes: panes.map { pane in
            FocusTopology.Pane(id: pane, tabs: [.init(id: "\(pane)-tab", kind: .terminal)], selected: "\(pane)-tab")
        })
    }
}
