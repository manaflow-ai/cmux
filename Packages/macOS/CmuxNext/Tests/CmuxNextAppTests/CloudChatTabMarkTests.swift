import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextIcons
@testable import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// cmux#51000, 2026-11-22: a chat sent to Cloud from the New Tab composer showed no cloud on its tab while it started, ran or
/// failed. The chat shows in place in this Mac's tab (``CloudFrontedChats``, cmux#47677), whose pane's daemon is this Mac's,
/// and only a tab in a Cloud machine's pane was badged. The tab now wears the cloud from the Send; the sidebar row is untouched.
@MainActor
struct CloudChatTabMarkTests {
    private static func page(_ store: DaemonStore, surface: UInt64) throws -> TabModel {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: nil, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 277, key: nil, name: "workspace-277", screens: [screen])]))
        return try #require(store.tab(surface: SurfaceID(rawValue: surface)))
    }

    /// The mark across a start's life: starting and failed on the New Tab page, running in place, none for a local chat.
    @Test func aCloudSendIsMarkedStartingFailedAndRunning() throws {
        let titles = AgentCloudStartTitles(), page = try Self.page(DaemonStore(), surface: 71)
        let mark = { (fronted: String?, local: Bool) in
            CloudChatTabMark.mark(agent: true, frontedMachine: fronted, sentToCloud: titles.sentToCloud(page), localSession: local)
        }
        #expect(mark(nil, false) == nil, "a New Tab page that sent nothing has no cloud")
        titles.begin(page, task: "1+1", untitled: "New Chat")
        #expect(mark(nil, false) == CloudChatTabMark(machine: nil), "starting")
        titles.end(page) // the runner's defer, on failure as on success
        #expect(mark(nil, false) == CloudChatTabMark(machine: nil), "a failed start keeps its cloud")
        #expect(mark(nil, true) == nil, "the tab then sent here instead: a local chat")
        titles.opened(page)
        #expect(!titles.sentToCloud(page))
        #expect(mark("cloud-machine-1", true) == CloudChatTabMark(machine: "cloud-machine-1"), "running in place: the machine's cloud")
        #expect(CloudChatTabMark.mark(agent: false, frontedMachine: nil, sentToCloud: true, localSession: false) == nil, "a terminal never")
    }

    /// 2026-11-24 (Austin): "we started the cloud chat but then for some reason the cloud icon didn't appear immediately on the horizontal
    /// tab". New Cloud Chat opens a workspace whose chat has Cloud picked; only its sidebar row read the workspace's mark, so its tab had
    /// no cloud until a Send. The tab wears it from the click, and a local chat in another workspace never does.
    @Test func newCloudChatsTabHasTheCloudFromTheClick() throws {
        let titles = AgentCloudStartTitles(), page = try Self.page(DaemonStore(), surface: 74)
        let mark = { (workspace: String?) in
            CloudChatTabMark.mark(agent: true, frontedMachine: nil, sentToCloud: titles.marksCloud(page, workspace: workspace), localSession: false)
        }
        #expect(mark("ws-cloud") == nil, "before the click")
        titles.beginWorkspace("ws-cloud")
        #expect(mark("ws-cloud") == CloudChatTabMark(machine: nil), "New Cloud Chat's tab, before any Send")
        #expect(mark("ws-local") == nil, "a tab of another workspace")
        #expect(mark(nil) == nil)
        titles.begin(page, task: "1+1", untitled: "New Chat")
        titles.endWorkspace("ws-cloud") // the runner's defer
        #expect(mark("ws-cloud") == CloudChatTabMark(machine: nil), "its start, then a failure, keep it")
    }

    /// A retry after a failure marks the tab again; another tab's send never marks this one.
    @Test func theMarkIsPerTab() throws {
        let store = DaemonStore(), titles = AgentCloudStartTitles()
        let page = try Self.page(store, surface: 72), other = try Self.page(DaemonStore(), surface: 73)
        titles.begin(page, task: "Fix it", untitled: "New Chat")
        #expect(titles.sentToCloud(page) && !titles.sentToCloud(other))
        titles.opened(page)
        titles.begin(page, task: "Fix it", untitled: "New Chat")
        #expect(titles.sentToCloud(page))
    }

    /// The tab strip's item for such a tab draws the cloud glyph in the trailing badge slot, named "Cloud" to VoiceOver,
    /// and its cell shows the glyph, not text.
    @Test func theTabDrawsTheCloudGlyph() throws {
        var item = TabItem(id: TabID("t"), title: "1+1")
        item.setCloudChatBadge(name: nil)
        #expect(item.machineBadgeIcon == .cloud)
        #expect(item.machineBadge == Strings.cloudMachineBadge)
        let (cell, close) = try CloudChatTabBadgeTests.cell(item)
        defer { close() }
        #expect(cell.machineIconLayer != nil, "no cloud glyph drawn")
        #expect(cell.machineLayer == nil)
    }
}
