import Foundation
import Testing
@testable import CmuxMobileModel

/// The Mac's Copy rows and New Tab positions on the phone (verify/parity-mac.md, Tabs).
@Suite struct TerminalToolsParityModelTests {
    static let ws = "ws_0123456789abcdef0123456789abcdef"
    static let pane = "pane_00112233445566778899aabbccddeeff"
    static let tab = "tab_ffeeddccbbaa99887766554433221100"

    /// The Mac's exact text (`CopyIdentifierActionsTests`).
    @Test func copyTextMatchesTheMac() {
        var workspace = Workspace(id: "k", macID: "m", title: "api", directory: "~/p", tabs: [], lastActivityAt: Date())
        #expect(workspace.copyIDText == nil && workspace.copyLinkText == nil)
        workspace.resourceID = Self.ws
        #expect(workspace.copyIDText == "workspace_id=\(Self.ws)")
        #expect(workspace.copyIDAndRefText == "workspace_ref=workspace:\(Self.ws)\nworkspace_id=\(Self.ws)")
        #expect(workspace.copyLinkText == "cmux://workspace/\(Self.ws)")

        var terminal = WorkspaceTab(id: "s1", kind: .terminal, title: "zsh")
        #expect(terminal.copyIDText == nil && terminal.copyLinkText == nil && terminal.copyIDsText(in: workspace) == nil)
        terminal.linkIDs = WorkspaceTab.LinkIDs(tab: Self.tab, pane: Self.pane)
        #expect(terminal.copyIDText == "surface_id=\(Self.tab)")
        #expect(terminal.copyPaneIDText == "pane_id=\(Self.pane)")
        #expect(terminal.copyPaneLinkText == "cmux://pane/\(Self.pane)")
        #expect(terminal.copyLinkText == "cmux://tab/\(Self.tab)")
        #expect(terminal.copyIDsText(in: workspace) == "workspace_id=\(Self.ws)\npane_id=\(Self.pane)\nsurface_id=\(Self.tab)")
        // An agent tab's link is its chat's acpmux session; none while the chat has none.
        var chat = WorkspaceTab(id: "s2", kind: .agent, title: "Claude", harness: "claude")
        chat.linkIDs = terminal.linkIDs
        #expect(chat.copyLinkText == nil)
        chat.linkIDs?.agentSession = "01a19a2c-e870-7db1-abef-e4e878b5f48f"
        #expect(chat.copyLinkText == "cmux://session/01a19a2c-e870-7db1-abef-e4e878b5f48f")
        chat.linkIDs?.agentSession = "a/../b"
        #expect(chat.copyLinkText == nil)
        // A malformed id is never written.
        terminal.linkIDs = WorkspaceTab.LinkIDs(tab: "tab_x y", pane: "p1")
        #expect(terminal.copyIDText == nil && terminal.copyPaneLinkText == nil)
    }

    /// `move-tab`'s insertion index for a new tab appended at the pane's end (the daemon's
    /// place) beside the tab at `anchor`.
    @Test func newTabPositionsMoveTheAppendedTab() {
        let pinned = [true, false, false, false, false] // the new tab is index 4
        // Same Kind goes where the Mac's default New Tab position puts it: after the current tab.
        #expect(NewTabPosition.sameKind.moveIndex(from: 4, anchor: 1, pinned: pinned) == 2)
        #expect(NewTabPosition.afterCurrent.moveIndex(from: 4, anchor: 1, pinned: pinned) == 2)
        #expect(NewTabPosition.afterCurrent.moveIndex(from: 4, anchor: 3, pinned: pinned) == nil)
        #expect(NewTabPosition.start.moveIndex(from: 4, anchor: 2, pinned: pinned) == 1)
        #expect(NewTabPosition.end.moveIndex(from: 4, anchor: 2, pinned: pinned) == nil)
        // A daemon that put it after the current tab: At End moves it forward (one past).
        #expect(NewTabPosition.end.moveIndex(from: 2, anchor: 1, pinned: pinned) == 5)
        // After a grouped tab: past its whole group (the Mac's NewTabSlot); never among pinned tabs.
        let groups: [String?] = [nil, "g", "g", nil, nil]
        #expect(NewTabPosition.afterCurrent.moveIndex(from: 4, anchor: 1, pinned: pinned, groups: groups) == 3)
        #expect(NewTabPosition.afterCurrent.moveIndex(from: 4, anchor: 0, pinned: [true, true, false, false, false]) == 2)
        #expect(NewTabPosition.allCases.map(\.title)
            == ["New Tab of the Same Kind", "New Tab to the Right", "New Tab at Start", "New Tab at End"])
    }
}
