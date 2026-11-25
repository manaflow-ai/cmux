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
    private static func workspace(_ store: DaemonStore, surface: UInt64 = 1, resource: String? = nil) throws -> (WorkspaceModel, TabModel) {
        var page = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
        page.tabResourceID = resource.map { ResourceID(rawValue: $0) }
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
        #expect(titles.title(of: page) == "Cloud row names" && titles.title(of: chat) == "Cloud row names",
                "the page keeps the title until its start ends (cmux#55540)")
        titles.end(page)
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

    /// cmux#55540: a New Tab chat sent in Cloud mode turns its Mac tab into the Cloud chat in place (`CloudFrontedChats`).
    /// Through the switch the tab read "New Tab", then "Agent" or the workspace's name, and the row "workspace-NNN": the
    /// hand-off ended the Mac tab's title before it showed the chat, and the title then rode on the chat's record, which its
    /// machine retitles ("Agent") and rebuilds. The Mac tab keeps the start's title until the chat has a title of its own.
    @Test func aMacTabKeepsTheStartsTitleThroughTheSwitchToItsCloudChat() throws {
        let titles = AgentCloudStartTitles(), prompt = "what's in this folder?"
        let (macWorkspace, mac) = try Self.workspace(DaemonStore(), surface: 1)
        let (_, opened) = try Self.workspace(DaemonStore(), surface: 2, resource: "tab_0123456789abcdef0123456789abcdef")
        var shown: TabModel?
        let reader = WorkspaceAutoNameReader(
            enabled: { true }, isNewTabPage: { $0 === mac && shown == nil }, livePage: { _ in nil }, incognitoTitle: { _ in nil },
            terminal: { _ in .init(kind: .terminal, userName: nil, title: nil, pageTitle: nil, url: nil, cwd: nil) },
            turns: AgentTurnStateStore(), hold: WorkspaceAutoNameHold(), cloudStarts: titles,
            shown: { $0 === mac ? shown : nil })
        titles.begin(mac, task: prompt, untitled: "Agent")
        titles.hand(from: mac, to: opened)
        // The chat's page paints before the Mac tab shows it: the Mac tab still reads as the start.
        #expect(titles.title(of: mac) == prompt, "the tab read New Tab while the chat's page painted")
        #expect(reader.label(macWorkspace, front: mac, work: nil) == prompt, "the row read workspace-NNN while the chat's page painted")

        // The Mac tab shows the chat in place (`CloudStartChat.front`), then the start's runner ends it.
        titles.opened(mac)
        shown = opened
        titles.end(mac)
        #expect(titles.title(of: mac) == nil && !titles.startsInCloud(mac), "the Mac tab is no New Tab page starting a chat now")
        #expect(titles.inPlaceTitle(of: mac) == prompt, "the start ended the title the Mac tab keeps for its chat")
        #expect(reader.label(macWorkspace, front: mac, work: nil) == prompt, "the row read workspace-NNN")

        // The chat's machine rebuilt its pane and titled the chat's record "Agent": the Mac tab still reads as the start.
        let rebuilt = try Self.chat(surface: 2, title: "Agent")
        shown = rebuilt
        #expect(titles.title(of: mac, showing: rebuilt, untitled: "Agent", turns: AgentTurnStateStore()) == prompt, "the tab read Agent")
        #expect(titles.title(of: mac, showing: try Self.chat(surface: 2, title: "about:blank"), untitled: "Agent",
                             turns: AgentTurnStateStore()) == prompt)
        #expect(reader.label(macWorkspace, front: mac, work: nil) == prompt, "the row read workspace-NNN")

        // Once the chat has a title of its own, it reads as that.
        #expect(titles.title(of: mac, showing: try Self.chat(surface: 2, title: "List the folder"), untitled: "Agent",
                             turns: AgentTurnStateStore()) == nil)

        // A new start from the same tab begins again: it reads as a starting page, not as the old chat.
        titles.begin(mac, task: "Second", untitled: "Agent")
        #expect(titles.title(of: mac) == "Second" && titles.inPlaceTitle(of: mac) == nil)
    }

    /// A Cloud chat's tab titled `title` on its machine (no resource id).
    private static func chat(surface: UInt64, title: String) throws -> TabModel {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: title, url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: nil, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 6, key: nil, name: "workspace-6", screens: [screen])]))
        return try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
    }
}
