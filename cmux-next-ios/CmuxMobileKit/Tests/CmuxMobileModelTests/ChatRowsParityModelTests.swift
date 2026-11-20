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

    @Test func messageAboutRefusesAnIDThatWouldBreakTheLink() {
        var workspace = Workspace(id: "w1", macID: "mac-1", title: "api", directory: "~/api", tabs: [], lastActivityAt: Date())
        workspace.resourceID = "ws_abc) [x](https://evil"
        #expect(ChiefMessageAbout(workspace: workspace) == nil)
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

    final class StopBackend: AgentChatsBackend {
        var stopped: [String] = []
        let refuse: Set<String>
        init(refuse: Set<String>) { self.refuse = refuse }
        func canListAgentChats(on macID: String) -> Bool { true }
        func agentChats(on macID: String, cursor: String?) async throws -> AgentChatPage { AgentChatPage(chats: [], nextCursor: nil) }
        func openAgentChat(_ chat: AgentChatListing, in workspace: Workspace) async throws -> WorkspaceTab { throw WorkspaceCreationError("no") }
        func openAgentChatInNewWorkspace(_ chat: AgentChatListing, on macID: String) async throws -> Workspace { throw WorkspaceCreationError("no") }
        func setAgentChatArchived(_ chat: AgentChatListing, archived: Bool, on macID: String) async throws -> AgentChatListing { chat }
        func openChatFolderInTerminal(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab { throw WorkspaceCreationError("no") }
        func stopAgentChat(_ chat: AgentChatListing, on macID: String) async throws {
            if refuse.contains(chat.id) {
                throw AgentChatOwnedByMac("This chat runs on the machine that started it, and only its owner can stop it")
            }
            if chat.id == "offline" { throw WorkspaceCreationError("Not connected") }
            stopped.append(chat.id)
        }
    }

    private func chat(_ id: String, _ status: String, archived: Bool = false) -> AgentChatListing {
        AgentChatListing(id: id, title: id, harness: "claude", cwd: "/p", status: status, updatedAt: nil, archived: archived)
    }

    @Test func stopAllStopsEveryWorkingChatAndCountsTheMacs() async {
        let backend = StopBackend(refuse: ["mac-started"])
        let result = await backend.stopAll([chat("a", "running"), chat("idle", "ready"), chat("b", "waiting"),
                                            chat("mac-started", "running"), chat("old", "running", archived: true)], on: "m")
        #expect(backend.stopped == ["a", "b"])
        #expect(result.stopped.map(\.id) == ["a", "b"])
        #expect(result.refused.map(\.id) == ["mac-started"])
        #expect(result.summary == "Stopped 2 agents. 1 started on the Mac keeps running: stop it on the Mac.")
        #expect(result.reason?.contains("only its owner can stop it") == true)
        let none = await StopBackend(refuse: []).stopAll([chat("x", "running")], on: "m")
        #expect(none.summary == "Stopped 1 agent.")
        // A chat it couldn't reach is not called the Mac's.
        let offline = await StopBackend(refuse: []).stopAll([chat("offline", "running")], on: "m")
        #expect(offline.refused.isEmpty && offline.failed.map(\.id) == ["offline"])
        #expect(offline.summary == "Stopped 0 agents. Couldn't stop 1.")
        #expect(offline.detail == "Not connected")
    }
}
