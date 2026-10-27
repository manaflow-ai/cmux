import AppKit
import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The chat indicators' acpmux watches at launch (p08-startup-097) through the app's own wiring: the real
/// `AppServices`, `ChatsFeed.postLaunchIndicators` and its real starts (`AgentTurnStateFeed`, the session tree, the
/// chat history that observes the Chats feed), on a socket no acpmux listens on. Nothing connects before the first
/// frame; an agent page or a Home view moves this Mac's watches to right after it. Each test ends with quit, which
/// drops every post not run: the Chief home's watch and the upload sweep never run here.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChatIndicatorsAfterFirstFrameTests {
    private static let local = ["AgentTurnStates.start", "SidebarSessionTree.start", "SidebarChatHistory.start"]

    /// App services whose Chats feed is on a fresh socket path in a folder that does not exist: a watch that
    /// starts waits for the socket, it never connects. This Mac's host is set, so no start reads `device-id`.
    private static func services() -> (AppServices, ChatsFeed) {
        AgentTurnStateFeed.shared = nil
        let services = AppServices(environment: AppEnvironment.current([:]))
        let socket = FileManager.default.temporaryDirectory
            .appending(path: "chat-indicators-\(UUID().uuidString)/acpmux.sock").path
        let feed = ChatsFeed(socketPath: socket, deadlines: services.mainDeadlines)
        services.chatsFeed = feed
        services.agentTabs.localHost = "install:this-mac"
        return (services, feed)
    }

    /// Nothing of the indicators started: no turn-state watch, no Chief watch, no observer on the Chats feed.
    private static func expectNothingStarted(_ feed: ChatsFeed, _ comment: Comment) {
        #expect(AgentTurnStateFeed.shared == nil, comment)
        #expect(ChatsFeed.chiefTurnStates == nil, comment)
        #expect(!feed.isObserved, comment)
    }

    @Test func aLaunchThatShowsNothingStartsNoWatchBeforeStartupCompletes() throws {
        let (services, feed) = Self.services()
        let s = StartupTestScheduler()
        feed.postLaunchIndicators(for: services, startup: s.startup)
        let launch = try #require(feed.launchIndicators, "the launch's indicator watches are posted")
        for _ in 0..<6 { s.fire() }
        Self.expectNothingStarted(feed, "no acpmux connect before the first frame")
        s.startup.firstFrameCommitted()
        for _ in 0..<6 { s.fire() }
        #expect(launch.started.isEmpty, "no window, page or sidebar shows them: they wait for startup")
        #expect(AgentTurnStateFeed.shared == nil)
        #expect(!feed.isObserved)
        s.startup.beginQuit()
    }

    @Test func anAgentPageStartsThisMacsWatchesRightAfterTheFirstFrame() throws {
        let (services, feed) = Self.services()
        let s = StartupTestScheduler()
        feed.postLaunchIndicators(for: services, startup: s.startup)
        let launch = try #require(feed.launchIndicators)
        services.agentTabs.pageShown()  // the agent tab store's page hook: `ChatsFeed.pageShown(in:)`
        #expect(launch.indicatorsNeeded, "the page hook reaches the launch's indicator watches")
        for _ in 0..<6 { s.fire() }
        Self.expectNothingStarted(feed, "a page shown before the first frame connects nothing before it")
        s.startup.firstFrameCommitted()
        for _ in 0..<8 { s.fire() }
        #expect(launch.started.prefix(Self.local.count).elementsEqual(Self.local), "this Mac's watches, in order")
        #expect(AgentTurnStateFeed.shared != nil, "this Mac's turn-state watch started")
        #expect(feed.isObserved, "the chat history observes the Chats feed, which connects it")
        #expect(s.startup.completion == nil, "they did not wait for startup")
        AgentTurnStateFeed.shared = nil
        s.startup.beginQuit()
    }

    @Test func aHomeViewNeedsTheIndicatorWatchesToo() throws {
        _ = NSApplication.shared
        let (services, feed) = Self.services()
        let s = StartupTestScheduler()
        services.home.postLaunchFeeds(startup: s.startup)
        feed.postLaunchIndicators(for: services, startup: s.startup)
        let launch = try #require(feed.launchIndicators)
        let page = TopHomePageView(services: services, windowKey: { "chat-indicators-after-first-frame" })
        #expect(launch.indicatorsNeeded, "a Home view moves this Mac's watches to right after the first frame")
        #expect(try #require(services.home.launchFeeds).isNeeded, "and Home's own feeds, as before")
        for _ in 0..<6 { s.fire() }
        Self.expectNothingStarted(feed, "nothing before the first frame")
        s.startup.beginQuit()
        _ = page
    }
}
