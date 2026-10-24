@testable import CmuxNextSidebar
import CmuxNextDesignTokens
import AppKit
import Testing

@MainActor
struct WorkspaceTabHoverCardTests {
    @Test func rowsReportTabDetailsAndReturnFocusesTheSelectedTab() throws {
        let view = WorkspaceTabHoverCardView()
        var selected: TabID?
        view.onSelect = { selected = $0 }
        view.configure(title: "leoli", tabs: [
            SidebarTab(id: TabID("shell"), title: "leoli", kind: .terminal, cwd: "~", status: .success),
            SidebarTab(id: TabID("claude"), title: "Claude Code", kind: .agentChat, cwd: "~/Projects/cmux", status: .working),
        ])

        #expect(view.reportedLines == ["leoli", "leoli · ~ · Done", "Claude Code · ~/Projects/cmux · Working"])
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                 windowNumber: 0, context: nil, characters: "\u{F701}",
                                                 charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        #expect(view.handleHoverCardKeyDown(down))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: 0, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(view.handleHoverCardKeyDown(enter))
        #expect(selected == TabID("claude"))
    }

    @Test func aSingleTabStillProducesAUsefulCard() {
        let view = WorkspaceTabHoverCardView()
        view.configure(title: "scratch", tabs: [
            SidebarTab(id: TabID("shell"), title: "shell", cwd: "~", status: .idle),
        ])
        #expect(view.reportedLines == ["scratch", "shell · ~ · Done"])
    }
}
