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

    /// REOPEN-F4 (STATUS 4618, 15 Cmd-Q keep + reopen cycles on cmux21): the restored window comes
    /// forward before its focused terminal's surface is shown, and AppKit makes the sidebar list its
    /// first key view. The app reports that as a programmatic responder change; the reducer took it as
    /// the person's choice, so the focus stayed on the sidebar (`keyboard: false`) and the first key a
    /// person typed went nowhere, in 10 of 15 cycles. The rule is cmux-focus-core's (#30356); the app
    /// gets it only through the pinned CCmuxAppFFI, so this test is red on a pin without it. A
    /// person's click on the sidebar still moves the focus there.
    @Test func theSidebarAppKitPicksAsARestoredWindowComesForwardNeverTakesTheRestoredTerminal() {
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-a"), workspaceKeys: [WorkspaceKey(rawValue: "ws-a")])
        record.focusedPane = "a2"
        let state = WindowState(record: record)
        let focused = FocusState.Resolved.terminal(pane: "a2", tab: "a2-tab")

        // The journal's order in the lost cycles: the topology, the window becomes key, then AppKit's first key view.
        state.focus.send(.topology(Self.topology("ws-a", panes: ["a1", "a2", "a3"])))
        state.focus.send(.windowKey(true))
        #expect(state.focus.state.resolved == focused)
        state.focus.responderDidChange(.sidebar, source: .programmatic)
        #expect(state.focus.state.resolved == focused,
                "the sidebar list AppKit picked took the restored terminal's keyboard: \(state.focus.state.resolved), target \(state.focus.state.target)")
        #expect(state.focus.state.target == .content)
        // The terminal's surface shows a frame later: the focus is still the restored terminal's.
        state.focus.send(.contentPresented(pane: "a2"))
        #expect(state.focus.state.resolved == focused)

        // The person's own click on the sidebar list still moves the focus there.
        state.focus.responderDidChange(.sidebar, source: .mouse)
        #expect(state.focus.state.resolved == .sidebar)
    }

    /// REOPEN-F5 (STATUS 4618, journey reopen-kill-all-scrollback, 2 of 3 on cmux21): after a kill of
    /// the app and every process of its bundle, the window reopens with its Home page column and one
    /// terminal; the line typed about 2 s after the terminals settled never reached the new shell. The
    /// same cause as F4: the sidebar AppKit picked as the window came forward kept the focus for good,
    /// so a key long after the terminal's surface showed still went to the sidebar list.
    @Test func aKillAllReopenWithAHomeColumnKeepsTheTerminalFocusedLongAfterItsSurfaceShows() {
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-h"), workspaceKeys: [WorkspaceKey(rawValue: "ws-h")])
        record.focusedPane = "term"
        let state = WindowState(record: record)
        let home = FocusTopology.Pane(id: "home", tabs: [.init(id: "home-tab", kind: .page)], selected: "home-tab")
        let terminal = FocusTopology.Pane(id: "term", tabs: [.init(id: "term-tab", kind: .terminal)], selected: "term-tab")
        let focused = FocusState.Resolved.terminal(pane: "term", tab: "term-tab")

        state.focus.send(.topology(FocusTopology(workspace: "ws-h", panes: [home, terminal],
                                                 screens: [[.init(id: "column:1", panes: ["home"]), .init(id: "column:2", panes: ["term"])]])))
        state.focus.send(.windowKey(true))
        state.focus.responderDidChange(.sidebar, source: .programmatic)
        state.focus.send(.contentPresented(pane: "home"))
        state.focus.send(.contentPresented(pane: "term"))
        // Nothing else happens until the typed line, about 2 s later (the lost cycles have no other focus event).
        state.focus.send(.appActive(true))
        #expect(state.focus.state.resolved == focused,
                "the typed line after a kill-all reopen goes to \(state.focus.state.resolved), not the restored terminal")
        #expect(state.focus.state.context.terminal, "the window does not publish a terminal focus: terminal shortcuts and typing miss it")
    }

    private static func topology(_ workspace: String, panes: [String]) -> FocusTopology {
        FocusTopology(workspace: workspace, panes: panes.map { pane in
            FocusTopology.Pane(id: pane, tabs: [.init(id: "\(pane)-tab", kind: .terminal)], selected: "\(pane)-tab")
        })
    }
}
