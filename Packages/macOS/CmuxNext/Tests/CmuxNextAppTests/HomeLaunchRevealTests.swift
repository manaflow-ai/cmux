import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
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

    /// Launch shell first, piece 3: Home paints from its saved state. Its page in its dock draws its
    /// list and last Chief from the Home cache, so Home is ready in the turn it mounts, with no
    /// Chief owner connected. The fresh launch rows showed Home only by its 1.5 s deadline
    /// (`reveal.home.by_deadline` in every run) while the owner came at 5.3 to 6.5 s.
    @Test func aHomeWhosePageIsInItsDockIsReadyWithoutTheChiefOwner() throws {
        let (services, reveal, window, content) = try Self.shown(kind: "home", screens: [Self.dockedPage()])
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        #expect(services.home.chief.connection == nil, "the test needs no Chief owner")
        #expect(reveal.isReady(.home), "Home's reveal waited for the Chief owner instead of its saved page")
        #expect(!reveal.shownByDeadline.contains(.home))
        #expect(content.contentView.alphaValue == 1)
    }

    /// A first launch: Home has no pane yet, then the dock step puts its page in the dock. Home shows
    /// in that turn, never by the deadline and never after the owner's first page.
    @Test func aHomeBeingMadeShowsOnceItsPageIsDocked() async throws {
        let (services, reveal, window, content) = try Self.shown(kind: "home")
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        #expect(content.contentView.alphaValue == 0)
        var workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "Home", screens: [Self.dockedPage()])
        workspace.kind = "home"
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [workspace]))
        content.applyCurrent()
        #expect(reveal.isReady(.home), "Home's page was docked and Home still waited")
        #expect(!reveal.shownByDeadline.contains(.home))
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

    /// The launch marks say whether Home showed by its data or by its deadline (goal next-launch-instant):
    /// `reveal.home` alone cannot, since a deadline 1.5 s after the hold looks like a slow first page.
    @Test func aRegionShownByItsDeadlineIsToldApartFromOneShownByItsData() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1500))
        let sidebar = NSView(), home = NSView()
        reveal.hold(sidebar, until: .sidebar)
        reveal.markReady(.sidebar)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1500))
        await Self.yield(until: { reveal.isReady(.pane) })
        reveal.hold(home, until: .home)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1500))
        await Self.yield(until: { reveal.isReady(.home) })
        #expect(reveal.shownByDeadline == [.home, .pane, .tabs], "only the regions whose data never came count as shown by deadline")
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

    /// Leo's NIGHTLY wrote no `launch-times.jsonl` line across six quit/relaunch rounds: his windows
    /// restore other workspaces, so Home is never held, its reveal never comes, and the record waited
    /// for it alone. A launch that never shows Home still records its times, once, after the wait.
    @Test func aLaunchThatNeverShowsHomeStillRecordsItsTimes() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1500))
        let firstFrame = FirstFrameGate()
        var writes = 0
        // As AppDelegate wires the launch-times record.
        firstFrame.whenOpen { reveal.whenReady(.home, orAfter: .seconds(10)) { writes += 1 } }
        firstFrame.open()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(10))
        await Self.yield(until: { writes > 0 })
        #expect(writes == 1, "a relaunch into another workspace wrote no launch-times record")
        reveal.markReady(.home)
        #expect(writes == 1, "Home showing later wrote the launch a second time")
    }

    /// A launch that shows Home records at its reveal, after the first frame, and the wait adds no second line.
    @Test func aLaunchThatShowsHomeRecordsOnceAtItsReveal() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1500))
        let firstFrame = FirstFrameGate()
        var writes = 0
        // As AppDelegate wires the launch-times record.
        firstFrame.whenOpen { reveal.whenReady(.home, orAfter: .seconds(10)) { writes += 1 } }
        firstFrame.open()
        try await clock.waitForSleeper()
        #expect(writes == 0, "the record was written before Home's reveal or the wait")
        reveal.markReady(.home)
        #expect(writes == 1, "Home showed after the first frame and nothing was recorded")
        clock.advance(by: .seconds(10))
        await Self.yield(until: { false })
        #expect(writes == 1)
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

    /// Home's page tab alone in its pinned left dock (as `HomeDock.ensure` leaves it).
    static func dockedPage() -> ScreenSnapshot {
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: HomeDock.page)
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true, allowsTabs: true)
        return ScreenSnapshot(id: 1, layout: .leaf(1), columns: [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1), dock: dock)],
                              panes: [PaneSnapshot(id: 1, tabs: [page])])
    }

    /// A workspace of `kind` with `screens` (none: no pane yet, Home as `ensure_home` returns it), shown in a window.
    static func shown(kind: String, screens: [ScreenSnapshot] = []) throws -> (AppServices, LaunchReveal, NSWindow, WorkspaceContentController) {
        let (services, reveal) = Self.services()
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        var workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "Home", screens: screens)
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
