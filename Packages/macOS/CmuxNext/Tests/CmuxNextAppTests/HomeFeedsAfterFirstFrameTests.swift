import AppKit
@testable import CmuxNextAgentPane
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextInput
import CmuxNextLaunch
import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Home and the New Tab page's feeds at launch, through the launch's own start list
/// (`HomeService.postLaunchFeeds`): posted after startup; a Home view or an agent page that shows moves
/// them to right after the first frame. No Chief owner, chats feed or Cloud read starts before the first
/// frame, and a Home view still draws the last launch's list from its cache (HomeLaunchListTests). Each
/// test ends with quit, which drops every post not run: no real Chief owner or feed starts here.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeFeedsAfterFirstFrameTests {
    private static let starts = ["Home.start", "ChatsFeed.keepCurrent", "ProjectsImport.start", "AgentPageChats.wire",
                                 "NewTabClosed.wire", "NewTabPlacesFeed.wire", "NewTabWeather.wire"]

    private static func records(_ s: StartupTestScheduler) -> [(name: String, priority: StartupPriority, ran: Bool)] {
        s.startup.log.records.map { ($0.name.description, $0.priority, $0.startNanos != nil) }
    }

    @Test func theLaunchPostsTheFeedsAfterStartupAsOnePost() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler()
        services.home.postLaunchFeeds(startup: s.startup)
        let feeds = try #require(services.home.launchFeeds)
        #expect(feeds.names == Self.starts)
        #expect(Self.records(s).map(\.name) == ["Home.start"], "one queued afterStartup post, not one per start")
        #expect(Self.records(s).allSatisfy { $0.priority == .afterStartup })
        s.startup.firstFrameCommitted()
        for _ in 0..<4 { s.fire() }
        #expect(feeds.started.isEmpty, "a launch with no Home or agent page keeps them out of the first frames")
        #expect(!services.home.chief.isRunning, "no Chief owner before startup completes")
        s.startup.beginQuit()
    }

    @Test func aHomeViewMovesTheFeedsToRightAfterTheFirstFrame() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler()
        services.home.postLaunchFeeds(startup: s.startup)
        let feeds = try #require(services.home.launchFeeds)
        let page = TopHomePageView(services: services, windowKey: { "feeds-after-first-frame" })
        #expect(feeds.isNeeded, "a Home view needs Home")
        let needed = Self.records(s).dropFirst()
        #expect(needed.map(\.name) == Self.starts.map { $0 + "Needed" })
        #expect(needed.allSatisfy { $0.priority == .afterFirstFrame }, "right after the first frame, not after startup")
        for _ in 0..<4 { s.fire() }
        #expect(Self.records(s).allSatisfy { !$0.ran }, "nothing runs before the first frame")
        #expect(feeds.started.isEmpty)
        #expect(!services.home.chief.isRunning, "no Chief owner before the first frame")
        s.startup.beginQuit()
        _ = page
    }

    @Test func anAgentPageMovesTheFeedsToRightAfterTheFirstFrame() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler()
        services.home.postLaunchFeeds(startup: s.startup)
        services.agentTabs.pageShown()
        #expect(try #require(services.home.launchFeeds).isNeeded, "the agent tab store's page hook is wired to the launch's feeds")
        s.startup.beginQuit()
    }

    /// The most common New Tab: the tab adopts the prewarmed spare (no ``AgentTabStore/view(for:)``
    /// build). Its adoption shows a page, as a standalone chat (onboarding, the quick composer) does;
    /// the spare made in the background does not.
    @Test func anAdoptedSpareAndAStandaloneChatAreShownPages() throws {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), work: BackgroundWork(label: "test.agent-pane"), webUI: .agentTabsTestHost(), input: InputEventTap(),
                                 environment: AgentPageAppTestRoot.environment, showcase: true)
        tabs.localHost = "install:this-mac"
        try #require(tabs.canHostChat, "no agent page source")
        var shown = 0
        tabs.pageShown = { shown += 1 }
        let store = DaemonStore()
        var blank = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        blank.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [blank])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        tabs.firstPageNewTab = { _, _ in
            (AgentPaneNewTab(kind: .agent), NewTabPageHandler(open: { _, _ in }, jump: { _, _, _ in }, editShortcut: { _ in }))
        }
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        #expect(shown == 0, "a prewarmed spare is not shown")
        tabs.takeSpare = { spare }
        let key = try #require(store.tab(surface: 1)?.id)
        let view = try #require(tabs.view(for: key))
        #expect(view === spare, "the tab adopted the spare")
        #expect(shown == 1, "an adopted spare is a shown page")
        _ = try #require(tabs.standaloneView(seed: AgentPaneSeed(cwd: "/tmp")))
        #expect(shown == 2, "a standalone chat is a shown page")
    }
}
