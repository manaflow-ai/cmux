@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-24, ask-97938b6c84: "terminal agent chats. can they be demarcated a bit differently/should they?
/// than gui agent chats". A row whose agent runs in a terminal (`SidebarWorkspace.agentInTerminal`) ends its
/// second line with "Terminal"; a GUI chat's row does not; a row without a second line stays one line.
@MainActor struct SidebarTerminalAgentLineTests {
    private let word = Strings.hoverCardKindTerminal

    private func row(inTerminal: Bool, lastMessage: String? = "Tests pass") -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("w"), machineID: .local, title: "app")
        ws.agentName = "Claude"
        ws.agentInTerminal = inTerminal
        ws.lastMessage = lastMessage
        return ws
    }

    private var expanded: SidebarLayoutOptions {
        var options = SidebarLayoutOptions()
        options.expanded = true
        return options
    }

    @Test func aTerminalAgentsSecondLineSaysTerminal() {
        let content = expanded.rowContent(row(inTerminal: true), machine: nil)
        #expect(content.detail == "Tests pass" + WorkspaceRowContent.separator + word)
    }

    @Test func aGUIChatsSecondLineIsUnchanged() {
        let content = expanded.rowContent(row(inTerminal: false), machine: nil)
        #expect(content.detail == "Tests pass")
    }

    @Test func aRowWithoutASecondLineIsUnchanged() {
        let options = SidebarLayoutOptions()
        let terminal = options.rowContent(row(inTerminal: true), machine: nil)
        #expect(terminal.detail == nil, "a one-line row grew a second line: \(terminal.detail ?? "")")
        #expect(terminal == options.rowContent(row(inTerminal: false), machine: nil))
    }

    @Test func aWorkingRowsNowLineSaysTerminalToo() {
        var ws = row(inTerminal: true)
        ws.agentStep = "Running tests"
        let content = expanded.rowContent(ws, machine: nil)
        #expect(content.now == "Running tests" + WorkspaceRowContent.separator + word)
    }

    @Test func aLineThatSaysTerminalAlreadyDoesNotSayItTwice() {
        let content = expanded.rowContent(row(inTerminal: true, lastMessage: "main" + WorkspaceRowContent.separator + word),
                                          machine: nil)
        #expect(content.detail == "main" + WorkspaceRowContent.separator + word)
    }
}
