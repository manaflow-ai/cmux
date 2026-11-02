import Foundation
import Testing
@testable import CmuxMobileModel

/// Send Message… to the Chief about a workspace or a tab, and New Agent Chat from Shortcuts.
@MainActor
@Suite struct ChatRowsParityModelTests {
    @Test func messageAboutStartsWithTheMacsLinkChip() {
        var workspace = Workspace(id: "w1", macID: "mac-1", title: "api [beta]", directory: "~/api", tabs: [], lastActivityAt: Date())
        #expect(ChiefMessageAbout(workspace: workspace) == nil, "no public id: no link")
        workspace.resourceID = "ws_0123456789abcdef0123456789abcdef"
        let subject = ChiefMessageAbout(workspace: workspace)
        #expect(subject?.link == "cmux://workspace/ws_0123456789abcdef0123456789abcdef")
        #expect(subject?.mention == "[api (beta)](cmux://workspace/ws_0123456789abcdef0123456789abcdef) ")
        #expect(subject?.macID == "mac-1")
        // The link parses back to what it names.
        #expect(subject.flatMap { URL(string: $0.link) }.flatMap(CmuxLink.init(url:))?.target == .workspace("ws_0123456789abcdef0123456789abcdef"))
    }

    @Test func messageAboutATabNamesTheTab() {
        let workspace = Workspace(id: "w1", macID: "mac-1", title: "api", directory: "~/api", tabs: [], lastActivityAt: Date())
        var tab = WorkspaceTab(id: "s4", kind: .terminal, title: "zsh")
        #expect(ChiefMessageAbout(tab: tab, in: workspace) == nil)
        tab.linkIDs = WorkspaceTab.LinkIDs(tab: "tab_00112233445566778899aabbccddeeff")
        let subject = ChiefMessageAbout(tab: tab, in: workspace)
        #expect(subject?.link == "cmux://tab/tab_00112233445566778899aabbccddeeff")
        #expect(subject?.mention.hasPrefix("[zsh](cmux://tab/") == true)
    }

    @Test func newAgentChatWaitsBrieflyForTheShell() {
        final class Clock { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let launcher = AgentChatLauncher(now: { clock.now })
        final class Seen { var prompts: [String?] = [] }
        let seen = Seen()
        launcher.start(prompt: "  fix the build  ")
        clock.now += 5
        launcher.handler = { seen.prompts.append($0) }
        #expect(seen.prompts == ["fix the build"])
        launcher.handler = nil
        launcher.start(prompt: "   ")
        clock.now += 60
        launcher.handler = { seen.prompts.append($0) }
        #expect(seen.prompts == ["fix the build"], "a start from minutes ago never opens a chat")
        launcher.start(prompt: nil)
        #expect(seen.prompts == ["fix the build", nil])
    }
}
