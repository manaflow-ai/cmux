import AppKit
import CmuxNextAgentActivity
import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The chat indicators' acpmux watches at launch (p08-startup-097) through the app's own wiring: the real
/// `AppServices` on the launch's scheduler, `ChatsFeed.postLaunchIndicators` and its real starts (`AgentTurnStateFeed`,
/// the session tree, the chat history that observes the Chats feed). Every acpmux watch connection goes through a fake
/// connector that records it: none before the first frame, and the agent host's prewarm (a daemon start) waits for it
/// too. Each test ends with quit, which drops every post not run.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChatIndicatorsAfterFirstFrameTests {
    private static let local = ["AgentTurnStates.start", "SidebarSessionTree.start", "SidebarChatHistory.start"]

    /// App services on `s`'s launch whose Chats feed connects through `connects`, to a socket file no acpmux listens
    /// on (a watch that starts connects, fails and backs off). This Mac's host is set unless `hostRead` is false.
    private static func services(_ s: StartupTestScheduler, _ connects: Connects, hostRead: Bool = true) -> AppServices {
        AgentTurnStateFeed.shared = nil
        AgentTurnStateStore.shared.localHost = nil
        let services = AppServices(environment: AppEnvironment.current([:]), launchStartup: s.startup)
        services.chatsFeed = ChatsFeed(socketPath: connects.socket, deadlines: services.mainDeadlines, connector: connects.connector)
        if hostRead { services.agentTabs.localHost = "install:this-mac" }
        return services
    }

    private static func started(_ s: StartupTestScheduler, _ name: String) -> Bool {
        s.startup.log.records.contains { $0.name.description == name && $0.startNanos != nil }
    }

    /// Nothing of the indicators connected or started before the first frame, and the agent host was not prewarmed.
    private static func expectNothingBeforeTheFirstFrame(_ s: StartupTestScheduler, _ connects: Connects, _ feed: ChatsFeed?) {
        #expect(connects.count == 0, "an acpmux watch connected before the first frame")
        #expect(AgentTurnStateFeed.shared == nil)
        #expect(feed?.isObserved == false)
        #expect(!started(s, "AgentTabs.prewarmHost"), "the agent host's prewarm (an acpmux start) ran before the first frame")
    }

    private static func finish(_ s: StartupTestScheduler, _ connects: Connects) {
        AgentTurnStateFeed.shared = nil
        s.startup.beginQuit()
        connects.remove()
    }

    @Test func aLaunchThatShowsNothingConnectsNothingBeforeStartupCompletes() throws {
        let s = StartupTestScheduler(), connects = try Connects()
        let services = Self.services(s, connects)
        ChatsFeed.postLaunchIndicators(for: services, startup: s.startup)
        let launch = try #require(services.chatIndicators, "the launch's indicator watches are posted")
        for _ in 0..<6 { s.fire() }
        Self.expectNothingBeforeTheFirstFrame(s, connects, services.chatsFeed)
        s.startup.firstFrameCommitted()
        for _ in 0..<6 { s.fire() }
        #expect(launch.started.isEmpty, "no window, page or sidebar shows them: they wait for startup")
        #expect(connects.count == 0)
        #expect(Self.started(s, "AgentTabs.prewarmHost"), "the agent host's prewarm runs right after the first frame")
        Self.finish(s, connects)
    }

    @Test func anAgentPageConnectsThisMacsWatchesRightAfterTheFirstFrame() throws {
        let s = StartupTestScheduler(), connects = try Connects()
        let services = Self.services(s, connects)
        ChatsFeed.postLaunchIndicators(for: services, startup: s.startup)
        let launch = try #require(services.chatIndicators)
        services.agentTabs.pageShown()  // the agent tab store's page hook: `ChatsFeed.pageShown(in:)`
        #expect(launch.indicatorsNeeded, "the page hook reaches the launch's indicator watches")
        for _ in 0..<6 { s.fire() }
        Self.expectNothingBeforeTheFirstFrame(s, connects, services.chatsFeed)
        s.startup.firstFrameCommitted()
        for _ in 0..<8 { s.fire() }
        #expect(launch.started.prefix(Self.local.count).elementsEqual(Self.local), "this Mac's watches, in order")
        #expect(AgentTurnStateFeed.shared != nil, "this Mac's turn-state watch started")
        #expect(AgentTurnStateStore.shared.localHost == "install:this-mac")
        #expect(services.chatsFeed?.isObserved == true, "the chat history observes the Chats feed")
        #expect(connects.count == 2, "the turn states' and the Chats feed's connections, after the first frame")
        #expect(s.startup.completion == nil, "they did not wait for startup")
        Self.finish(s, connects)
    }

    /// The launch's read of the install id (p08-startup-076) still runs when the page's watches start: the
    /// turn-state watch keeps the host it starts with, so it waits for that read and starts with this Mac's host,
    /// never with nil for the session.
    @Test func aDeviceIDReadStillPendingAtTheFirstFrameIsWaitedFor() throws {
        let s = StartupTestScheduler(), connects = try Connects()
        let services = Self.services(s, connects, hostRead: false)
        let tabs = services.agentTabs
        var read: String?
        var pending: [@MainActor @Sendable () -> Void] = []
        tabs.resolveLocalHost = { read }
        tabs.awaitLocalHostRead = { pending.append($0) }
        ChatsFeed.postLaunchIndicators(for: services, startup: s.startup)
        tabs.pageShown()
        s.startup.firstFrameCommitted()
        for _ in 0..<8 { s.fire() }
        #expect(services.chatIndicators?.started.prefix(Self.local.count).elementsEqual(Self.local) == true)
        #expect(AgentTurnStateFeed.shared == nil, "a watch started while the id read ran")
        #expect(connects.count == 0)
        #expect(pending.count == Self.local.count, "each start waits for the read")
        read = "install:this-mac"  // the launch's read ends
        for body in pending { body() }
        #expect(AgentTurnStateStore.shared.localHost == "install:this-mac", "the turn states kept a nil host")
        #expect(connects.count == 2)
        Self.finish(s, connects)
    }

    @Test func aHomeViewNeedsTheIndicatorWatchesToo() throws {
        _ = NSApplication.shared
        let s = StartupTestScheduler(), connects = try Connects()
        let services = Self.services(s, connects)
        services.home.postLaunchFeeds(startup: s.startup)
        ChatsFeed.postLaunchIndicators(for: services, startup: s.startup)
        let launch = try #require(services.chatIndicators)
        let page = TopHomePageView(services: services, windowKey: { "chat-indicators-after-first-frame" })
        #expect(launch.indicatorsNeeded, "a Home view moves this Mac's watches to right after the first frame")
        #expect(try #require(services.home.launchFeeds).isNeeded, "and Home's own feeds, as before")
        for _ in 0..<6 { s.fire() }
        Self.expectNothingBeforeTheFirstFrame(s, connects, services.chatsFeed)
        Self.finish(s, connects)
        _ = page
    }
}

/// A socket path that exists (a plain file, so a watch connects and fails) and a connector that counts the opens.
private final class Connects {
    let root: URL
    let socket: String
    private let opens = Opens()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "chat-indicators-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socket = root.appending(path: "acpmux.sock").path
        try Data().write(to: URL(fileURLWithPath: socket))
    }

    var connector: AgentActivityConnector {
        AgentActivityConnector { [opens, socket] path in
            if path == socket { opens.add() }  // this Mac's watches (a Chief home watch has its own socket)
            return AgentActivityLineConnection(path: path)
        }
    }

    /// The connections to ``socket`` opened so far.
    var count: Int { opens.count }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// How many connections the connector opened, from any thread.
private nonisolated final class Opens: Sendable {
    private let state = Mutex(0)

    var count: Int { state.withLock { $0 } }

    func add() { state.withLock { $0 += 1 } }
}
