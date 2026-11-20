@testable import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// 2026-11-10, a Cloud chat sent from a new workspace's New Tab page: while the start ran its row read "workspace-6"
/// with no cloud mark and its tab "New Tab". The page is a workspace of this Mac until the chat opens on its machine,
/// and the cloud mark was drawn only for rows of a Cloud machine (`SidebarLayoutOptions.cloudMachines`), the title only
/// from a chat. From the Send the page's tab and row read as the chat it starts and the row draws the cloud mark.
@MainActor
struct CloudStartRowTests {
    private static func page(_ store: DaemonStore, surface: UInt64) throws -> TabModel {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: nil, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 6, key: nil, name: "workspace-6", screens: [screen])]))
        return try #require(store.tab(surface: SurfaceID(rawValue: surface)))
    }

    @Test func theSendingPagesTabReadsAsItsChatWhileTheStartRuns() throws {
        let titles = AgentCloudStartTitles(), page = try Self.page(DaemonStore(), surface: 61)
        var strip = TabTitleResolver(newTabPages: [page.id])
        strip.cloudStarts = titles
        strip.chatTitle = { _ in AgentPaneModel.tabTitle }
        let before = strip.title(page)
        titles.begin(page, task: "Fix the flaky login test\nIt fails on CI.", untitled: AgentPaneModel.tabTitle)
        #expect(strip.title(page) == "Fix the flaky login test", "the tab read \(before)")
        titles.end(page)
        #expect(strip.title(page) == before, "a failed start's page reads as its page again")
    }

    /// The chat that opened on the machine, with no title of its own on this Mac yet, keeps the start's title.
    @Test func theOpenedChatsTabKeepsTheTitle() throws {
        let titles = AgentCloudStartTitles(), page = try Self.page(DaemonStore(), surface: 62)
        let chat = try Self.page(DaemonStore(), surface: 63)
        var strip = TabTitleResolver(newTabPages: [page.id])
        strip.cloudStarts = titles
        strip.chatTitle = { _ in AgentPaneModel.tabTitle }
        #expect(strip.title(chat) == AgentPaneModel.tabTitle, "fixture: a chat with no title")
        titles.begin(page, task: "Title: Cloud row names", untitled: AgentPaneModel.tabTitle)
        titles.hand(from: page, to: chat)
        #expect(strip.title(chat) == "Cloud row names")
    }

    /// cmux#47678: a Cloud start that failed ("Couldn't copy the folder to cloud-chats-12: …") read as a plain local page,
    /// with nothing saying it was a Cloud chat. It keeps the start's title and the cloud mark, and its row's line names
    /// the machine it took, until a Retry begins it again or the page starts a chat of its own; an opened start (or Run on
    /// This Mac) ends it as before.
    @Test func aFailedStartStillReadsAsACloudChatOnItsMachine() throws {
        let titles = AgentCloudStartTitles(), store = DaemonStore(), page = try Self.page(store, surface: 64)
        titles.begin(page, task: "1+1", untitled: AgentPaneModel.tabTitle)
        #expect(titles.failedStart(of: page) == nil, "a running start is no failure")
        titles.ended(page, opened: false, machine: "cloud-chats-12")
        #expect(titles.startsInCloud(page) && titles.title(of: page) == "1+1")
        #expect(titles.failedStart(of: page) == .some("cloud-chats-12"))
        #expect(CloudMoveStrings.startFailedRow(machine: "cloud-chats-12") == "Cloud · cloud-chats-12 · Couldn't start")
        #expect(CloudMoveStrings.startFailedRow(machine: nil) == "Cloud · Couldn't start")
        titles.begin(page, task: "1+1", untitled: AgentPaneModel.tabTitle)
        #expect(titles.failedStart(of: page) == nil && titles.startsInCloud(page), "Retry runs the start again")
        titles.ended(page, opened: false, machine: nil)
        #expect(titles.failedStart(of: page) == .some(nil), "failed before it had a machine")
        titles.ended(page, opened: true, machine: nil)
        #expect(!titles.startsInCloud(page), "an opened start's page reads as its page again")

        let local = try Self.page(store, surface: 65)
        titles.begin(local, task: "1+1", untitled: AgentPaneModel.tabTitle)
        titles.ended(local, opened: false, machine: "cloud-chats-12")
        var tab = TabSnapshot(surface: SurfaceID(rawValue: 65), kind: .conversation, title: "1+1", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: "chat-local", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 6, key: nil, name: "workspace-6", screens: [screen])]))
        let sent = try #require(store.tab(surface: SurfaceID(rawValue: 65)))
        #expect(!titles.startsInCloud(sent) && titles.failedStart(of: sent) == nil, "a local chat sent after the failure read as Cloud")
    }

    /// cmux#45947: New Cloud Chat opens a workspace of its own whose row reads as Cloud from the click, before any Send,
    /// and reads as this Mac's again once its start ended (refused or failed: the chat stays here).
    @Test func newCloudChatsWorkspaceReadsAsCloudFromTheClickUntilItsStartEnds() {
        let titles = AgentCloudStartTitles()
        #expect(!titles.startsInCloud(workspace: "ws-new"))
        titles.beginWorkspace("ws-new")
        #expect(titles.startsInCloud(workspace: "ws-new") && !titles.startsInCloud(workspace: "ws-other"))
        titles.endWorkspace("ws-new")
        #expect(!titles.startsInCloud(workspace: "ws-new"), "a start that ended left its row drawn as Cloud")
        titles.endWorkspace(nil)
    }

    /// A row of this Mac whose page is starting a Cloud chat draws the cloud mark and VoiceOver says Cloud; it names
    /// no machine. Another row of this Mac draws none.
    @Test func aStartingRowOfThisMacHasTheCloudMark() throws {
        let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var starting = SidebarWorkspace(id: WorkspaceID("ws-6"), machineID: mac.id, title: "Fix the flaky login test")
        starting.startsInCloud = true
        let plain = SidebarWorkspace(id: WorkspaceID("ws-7"), machineID: mac.id, title: "api")
        let model = SidebarModel(sections: [SidebarRowSection(kind: .machine(mac), nodes: [.workspace(starting), .workspace(plain)])])
        let layout = SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
        let content = { (id: String) in layout.rows.first { $0.key == .workspace(WorkspaceID(id)) }?.content }
        let row = try #require(content("ws-6"))
        #expect(row.runsInCloud && row.machine == nil, "the row of a starting Cloud chat drew no cloud mark")
        #expect(try #require(content("ws-7")).runsInCloud == false)
        let label = WorkspaceRowView.accessibilityText(starting, content: row, tabCount: nil, presence: [])
        #expect(label.contains("Cloud") && !label.contains("This Mac"), "\(label)")
    }
}
