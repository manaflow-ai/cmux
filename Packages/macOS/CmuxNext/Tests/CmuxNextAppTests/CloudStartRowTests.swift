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
@MainActor @Suite(.serialized)
struct CloudStartRowTests {
    private static func page(_ store: DaemonStore, surface: UInt64) throws -> TabModel {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: nil, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 6, key: nil, name: "workspace-6", screens: [screen])]))
        return try #require(store.tab(surface: SurfaceID(rawValue: surface)))
    }

    @Test func theSendingPagesTabReadsAsItsChatWhileTheStartRuns() throws {
        let titles = AgentCloudStartTitles.shared, page = try Self.page(DaemonStore(), surface: 61)
        defer { titles.end(page) }
        var strip = TabTitleResolver(newTabPages: [page.id])
        strip.chatTitle = { _ in AgentPaneModel.tabTitle }
        let before = strip.title(page)
        titles.begin(page, task: "Fix the flaky login test\nIt fails on CI.", untitled: AgentPaneModel.tabTitle)
        #expect(strip.title(page) == "Fix the flaky login test", "the tab read \(before)")
        titles.end(page)
        #expect(strip.title(page) == before, "a failed start's page reads as its page again")
    }

    /// The chat that opened on the machine, with no title of its own on this Mac yet, keeps the start's title.
    @Test func theOpenedChatsTabKeepsTheTitle() throws {
        let titles = AgentCloudStartTitles.shared, page = try Self.page(DaemonStore(), surface: 62)
        let chat = try Self.page(DaemonStore(), surface: 63)
        defer { titles.end(chat) }
        var strip = TabTitleResolver(newTabPages: [page.id])
        strip.chatTitle = { _ in AgentPaneModel.tabTitle }
        #expect(strip.title(chat) == AgentPaneModel.tabTitle, "fixture: a chat with no title")
        titles.begin(page, task: "Title: Cloud row names", untitled: AgentPaneModel.tabTitle)
        titles.hand(from: page, to: chat)
        #expect(strip.title(chat) == "Cloud row names")
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
