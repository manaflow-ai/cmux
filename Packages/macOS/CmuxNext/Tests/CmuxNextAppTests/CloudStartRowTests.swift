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

    /// cmux#55540: the Mac tab that shows its Cloud chat in place read "Agent" (the chat's record's title on its machine) or
    /// its workspace's name once the start handed off. It reads as the start's prompt until the chat has a title of its own.
    @Test func aMacTabShowingItsCloudChatInPlaceReadsAsTheStart() throws {
        let titles = AgentCloudStartTitles(), mac = try Self.page(DaemonStore(), surface: 64)
        var chatSnapshot = TabSnapshot(surface: SurfaceID(rawValue: 65), kind: .conversation, title: AgentPaneModel.tabTitle, url: "about:blank")
        chatSnapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:cloud", session: nil, harness: "claude"))
        let cloud = DaemonStore()
        cloud.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 7, key: nil, name: "workspace-7", screens: [
            ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chatSnapshot])])])]))
        let chat = try #require(cloud.tab(surface: SurfaceID(rawValue: 65)))
        var strip = TabTitleResolver(newTabPages: [])
        strip.cloudStarts = titles
        strip.workspaceName = "workspace-6"
        strip.chatTitle = { _ in AgentPaneModel.tabTitle }
        strip.fronted = { $0 === mac ? chat : nil }
        #expect(strip.title(mac) != "List the folder", "fixture: the chat has no title of its own")
        titles.begin(mac, task: "List the folder", untitled: AgentPaneModel.tabTitle)
        titles.hand(from: mac, to: chat)
        titles.opened(mac)
        titles.end(mac)
        #expect(strip.title(mac) == "List the folder", "the tab read \(AgentPaneModel.tabTitle) or workspace-6")
    }

    /// cmux#45947: New Cloud Chat opens a workspace of its own whose chat tab reads as Cloud from the click, before any Send
    /// (``AgentCloudStartTitles/marksCloud(_:workspace:)``), and as this Mac's again once its start ended. Its sidebar row never
    /// draws a cloud (cmux#55668).
    @Test func newCloudChatsWorkspaceReadsAsCloudFromTheClickUntilItsStartEnds() {
        let titles = AgentCloudStartTitles()
        #expect(!titles.startsInCloud(workspace: "ws-new"))
        titles.beginWorkspace("ws-new")
        #expect(titles.startsInCloud(workspace: "ws-new") && !titles.startsInCloud(workspace: "ws-other"))
        titles.endWorkspace("ws-new")
        #expect(!titles.startsInCloud(workspace: "ws-new"), "a start that ended left its tab drawn as Cloud")
        titles.endWorkspace(nil)
    }
}
