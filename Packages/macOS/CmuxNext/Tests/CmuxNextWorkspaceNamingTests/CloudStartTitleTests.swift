import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWorkspaceNaming
import Testing

/// 2026-11-10, a Cloud chat sent from a new workspace's New Tab page: while the start ran (machine, copy, opening) its
/// row read "workspace-6" and its tab "New Tab", because the page stayed a New Tab page until the chat opened on its
/// machine and nothing told the row or the tab what it was starting. From the Send the page reads as its chat, its
/// first prompt's naming line, as a local chat does; the chat it opens keeps that title until it has its own here.
@MainActor
struct CloudStartTitleTests {
    private static let host = "install:cloud-start-title"

    /// Workspace "workspace-6" whose one tab is an agent tab with no chat yet (the New Tab page, or a Cloud chat just opened).
    private static func workspace(_ store: DaemonStore, surface: UInt64 = 1) throws -> (WorkspaceModel, TabModel) {
        var page = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: nil, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 6, key: nil, name: "workspace-6", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        return (workspace, try #require(workspace.screens.first?.panes.first?.tabs.first))
    }

    private static func reader(_ titles: AgentCloudStartTitles, page: Bool) -> WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(enabled: { true }, isNewTabPage: { _ in page }, livePage: { _ in nil }, incognitoTitle: { _ in nil },
                                terminal: { _ in .init(kind: .terminal, userName: nil, title: nil, pageTitle: nil, url: nil, cwd: nil) },
                                turns: AgentTurnStateStore(), hold: WorkspaceAutoNameHold(), cloudStarts: titles)
    }

    @Test func theSendingPageReadsAsItsChatUntilTheStartEnds() throws {
        let titles = AgentCloudStartTitles(), store = DaemonStore()
        let (workspace, page) = try Self.workspace(store)
        let reader = Self.reader(titles, page: true)
        #expect(reader.label(workspace, front: page, work: nil) == nil, "fixture: a New Tab page names nothing")

        titles.begin(page, task: "Fix the flaky login test\nIt fails on CI about once a day.", untitled: "Agent")
        #expect(titles.startsInCloud(page))
        #expect(titles.title(of: page) == "Fix the flaky login test")
        #expect(reader.label(workspace, front: page, work: nil) == "Fix the flaky login test", "the row read workspace-6")

        // A failed start: the page is the page again, and the row's name is not held over.
        titles.end(page)
        #expect(!titles.startsInCloud(page) && titles.title(of: page) == nil)
        #expect(reader.label(workspace, front: page, work: nil) == nil)
    }

    @Test func aStartOfOnlyAttachmentsReadsUntitled() throws {
        let titles = AgentCloudStartTitles()
        let (_, page) = try Self.workspace(DaemonStore())
        titles.begin(page, task: "  \n", untitled: "Agent")
        #expect(titles.title(of: page) == "Agent")
    }

    /// The chat that opened on the machine takes the start's title, which leaves the page; until its chat has a
    /// title on this Mac the chat's row reads it rather than its machine's `workspace-N`.
    @Test func theOpenedChatKeepsTheTitle() throws {
        let titles = AgentCloudStartTitles()
        let (_, page) = try Self.workspace(DaemonStore())
        let cloudStore = DaemonStore()
        let (cloudWorkspace, chat) = try Self.workspace(cloudStore, surface: 20)
        titles.begin(page, task: "Title: Cloud row names\nmore", untitled: "Agent")
        titles.hand(from: page, to: chat)
        #expect(titles.title(of: page) == nil && titles.title(of: chat) == "Cloud row names")
        #expect(Self.reader(titles, page: false).label(cloudWorkspace, front: chat, work: nil) == "Cloud row names")
    }

    /// Held by the record's identity: another tab with the same id (another daemon's `surface:1`) never reads it.
    @Test func anotherTabWithTheSameIDDoesNotReadIt() throws {
        let titles = AgentCloudStartTitles()
        let (_, page) = try Self.workspace(DaemonStore())
        let (_, other) = try Self.workspace(DaemonStore())
        #expect(page.id == other.id && page !== other, "fixture")
        titles.begin(page, task: "Fix it", untitled: "Agent")
        #expect(titles.title(of: other) == nil)
    }
}
