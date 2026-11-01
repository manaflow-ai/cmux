import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Leo's never-blank first launch frame: a first launch shows Home settled, not in pieces. A cold
/// launch showed the home workspace's "Start something new" at 3049 ms, then the second column and
/// import cards, then the header, actions and message box at about 4978 ms: Home is made over
/// several daemon replies (the dock's page tab, then the Chief conversation) and no launch region
/// held it. A Home with no pane yet stays clear until its conversation's first page is in.
@MainActor @Suite(.serialized, .closesItsWindows)
struct HomeLaunchRevealTests {
    @Test func aHomeStillBeingMadeStaysClearUntilItsConversationIsIn() throws {
        let (services, reveal, window, content) = try Self.shown(kind: "home")
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        #expect(content.contentView.alphaValue == 0, "a Home with no pane yet drew its pieces as they came")
        reveal.markReady(.home)
        #expect(content.contentView.alphaValue == 1)
    }

    @Test func anotherWorkspaceWithNoPaneIsNotHeld() throws {
        let (services, _, window, content) = try Self.shown(kind: "normal")
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        #expect(content.contentView.alphaValue == 1, "only Home waits for its conversation")
    }

    @Test func homeIsReadyOnceItsConversationsFirstPageIsIn() async {
        let (services, reveal) = Self.services()
        let view = HomeHostView(services: services, conversation: "conv_local")
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let deadline = ContinuousClock.now + .seconds(10)
        // Polls a state the view reaches on its own turns (the offline store answering the open).
        while !reveal.isReady(.home), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(reveal.isReady(.home), "Home's first page came in and the launch still held Home")
        withExtendedLifetime(view) {}
    }

    /// Home is made after the launch window (3049 ms on a cold launch, the sidebar's hold long
    /// before): the launch deadline must not release it before it is held, and its own wait runs
    /// from its own hold. The other regions still show at the launch deadline.
    @Test func aHomeHeldAfterTheLaunchDeadlineWaitsItsOwn() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1500))
        let sidebar = NSView(), home = NSView()
        reveal.hold(sidebar, until: .sidebar)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1500))
        await Self.yield(until: { reveal.isReady(.sidebar) })
        #expect(reveal.isReady(.sidebar) && reveal.isReady(.pane), "the launch deadline still shows the window's regions")
        reveal.hold(home, until: .home)
        #expect(home.alphaValue == 0, "the launch deadline released Home before it was made: it came in pieces")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1500))
        await Self.yield(until: { reveal.isReady(.home) })
        #expect(home.alphaValue == 1, "a Home whose conversation never came stayed clear past its own deadline")
    }

    /// A Home closed before its page came (a fresh Home replaced it) leaves its deadline behind:
    /// the Home that replaced it waits its own, never the closed one's remainder.
    @Test func aHomeThatReplacesAClosedOneWaitsItsOwnDeadline() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1500))
        let first = NSView(), second = NSView()
        reveal.hold(first, until: .home)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1000))
        reveal.release(first)
        reveal.hold(second, until: .home)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(600))
        await Self.yield(until: { reveal.isReady(.home) })
        #expect(second.alphaValue == 0, "the replacing Home showed at the closed Home's deadline, before its page")
        clock.advance(by: .milliseconds(900))
        await Self.yield(until: { reveal.isReady(.home) })
        #expect(second.alphaValue == 1, "the replacing Home stayed clear past its own deadline")
    }

    // MARK: Fixtures

    /// Lets a timer that fired run its main-actor work.
    static func yield(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    /// A reveal whose deadline never fires during a test.
    static func services() -> (AppServices, LaunchReveal) {
        _ = NSApplication.shared
        let reveal = LaunchReveal(deadline: .seconds(60))
        return (AppServices(environment: AppEnvironment.current([:]), launchReveal: reveal), reveal)
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"home-launch-reveal-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// A workspace of `kind` with no pane yet (Home as `ensure_home` returns it), shown in a window.
    static func shown(kind: String) throws -> (AppServices, LaunchReveal, NSWindow, WorkspaceContentController) {
        let (services, reveal) = Self.services()
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        var workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "Home")
        workspace.kind = kind
        store.apply(snapshot: DaemonTree(workspaces: [workspace]))
        let model = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: model, daemon: services.daemon, services: services, state: WindowState(record: record))
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        return (services, reveal, window, content)
    }
}
