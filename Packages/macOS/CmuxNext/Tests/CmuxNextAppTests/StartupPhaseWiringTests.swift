import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// The startup phases wired to the app (p06-scheduler-007): `LaunchReveal`'s last produced region
/// reveals the launch, and `StartupReferences` marks the settle references (the daemon store's
/// first snapshot, the window restore, the visible page's first load, an unavailable daemon).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct StartupPhaseWiringTests {
    @MainActor private final class Count {
        var value = 0
    }

    /// The daemon's startup as `StartupReferences.watchUnavailable` reads it.
    @MainActor @Observable final class Daemon {  // not private: the macro's conformance extension must reach it
        var isUnavailable = false
    }

    /// A front page whose load state is observable, as a `BrowserTab`'s is.
    @MainActor @Observable final class Page {  // not private, as Daemon
        var state = BrowserTabState()
        private var machine = BrowserTabStateMachine()
        private var navigation: UInt64 = 0

        func start() {
            navigation += 1
            apply(.started(BrowserNavigationID(rawValue: navigation), url: URL(string: "https://example.com")))
        }

        func finish() { apply(.finished(BrowserNavigationID(rawValue: navigation))) }

        private func apply(_ event: BrowserNavigationEvent) {
            machine.apply(event)
            state = machine.state
        }
    }

    /// What the front pane shows, read the way `WindowManager.visiblePageLoad` reads panes: not
    /// observable, so only a content change makes it read again.
    @MainActor private final class Front {
        var page: Page?
    }

    private static func tree() -> DaemonTree {
        DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [])])
    }

    private func reached(_ phase: StartupPhase.Phase, _ startup: StartupPhase) async {
        await withCheckedContinuation { continuation in startup.whenReached(phase) { continuation.resume() } }
    }

    /// A startup phase revealed by a first frame, with only the given references left.
    private func revealed(leaving left: Set<StartupPhase.Reference>) -> StartupPhase {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        startup.noteFirstFrame()
        for reference in Set(StartupPhase.Reference.allCases).subtracting(left).subtracting([.firstFrame]) { startup.markDone(reference) }
        return startup
    }

    @Test func theLastLaunchRegionRevealsTheLaunchOnce() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let revealed = Count()
        let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60)) {
            revealed.value += 1
            startup.noteFirstFrame()
        }
        var order: [String] = []
        startup.whenReached(.revealed) { order.append("launch.revealed") }
        startup.whenReached(MainWorkClass.background.startupOpening) { order.append("background") }

        reveal.markReady(.sidebar)
        reveal.markReady(.tabs)
        #expect(!reveal.isRevealed)
        #expect(startup.phase == .launching, "a region still held keeps the launch launching")
        #expect(order.isEmpty, "no background work before the reveal")

        reveal.markReady(.pane)
        #expect(reveal.isRevealed)
        #expect(revealed.value == 1)
        #expect(startup.phase == .revealed)
        #expect(startup.revealCause == .firstFrame)
        #expect(order == ["launch.revealed", "background"], "the reveal mark comes before any background task")

        reveal.markAllReady()
        reveal.markReady(.pane)
        #expect(revealed.value == 1, "the reveal callback runs once")
    }

    /// The deadline shows every region with no data: it is not a first frame. The data landing
    /// after it is.
    @Test func theRevealDeadlineIsNotTheFirstFrame() async throws {
        let clock = ManualClock()
        let revealed = Count()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1_500)) { revealed.value += 1 }
        reveal.hold(NSView(), until: .pane)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_500))
        await withCheckedContinuation { continuation in reveal.whenReady(.pane) { continuation.resume() } }
        #expect(reveal.isRevealed, "every region shows at the deadline")
        #expect(revealed.value == 0, "the deadline paints no data")

        reveal.markReady(.sidebar)
        reveal.markReady(.tabs)
        #expect(revealed.value == 0)
        reveal.markReady(.pane)
        #expect(revealed.value == 1, "the last region's data after the deadline is the first frame")
    }

    @Test func theFirstSnapshotCallbackRunsOnceForTheLiveTree() {
        let store = DaemonStore()
        let ran = Count()
        store.whenFirstSnapshotApplied { ran.value += 1 }
        store.applyProvisional(snapshot: Self.tree())
        #expect(ran.value == 0, "the launch snapshot is not the live tree")
        store.apply(snapshot: Self.tree())
        #expect(ran.value == 1)
        store.apply(snapshot: Self.tree())
        #expect(ran.value == 1, "later snapshots do not run it again")
        store.whenFirstSnapshotApplied { ran.value += 1 }
        #expect(ran.value == 2, "asked after the first snapshot, it runs at once")
    }

    /// The reveal deadline (which used to end the unavailable watch with the pane settle) comes
    /// first; the daemon is unavailable after it. Startup still settles on its references.
    @Test func anUnavailableDaemonAfterTheRevealDeadlineSettlesOnReferences() async throws {
        let startupClock = ManualClock()
        let startup = StartupPhase(clock: startupClock, ledger: WakeupLedger())
        let revealClock = ManualClock()
        let reveal = LaunchReveal(clock: revealClock, deadline: .milliseconds(1_500)) { startup.noteFirstFrame() }
        let references = StartupReferences(startup: startup, reveal: reveal)
        let daemon = Daemon()
        references.watchUnavailable { [daemon] in daemon.isUnavailable }

        reveal.hold(NSView(), until: .pane)
        try await revealClock.waitForSleeper()
        revealClock.advance(by: .milliseconds(1_500))
        try await startupClock.waitForSleeper()
        startupClock.advance(by: .milliseconds(1_500))
        await reached(.revealed, startup)
        #expect(reveal.isRevealed)
        #expect(startup.revealCause == .deadline)
        #expect(startup.pendingReferences == Set(StartupPhase.Reference.allCases))

        daemon.isUnavailable = true
        await reached(.settled, startup)
        #expect(startup.settleCause == .references, "the unavailable daemon settles startup without the failsafe")
    }

    @Test func restoreMarksItsReferenceAndAPageWithNoLoadYetWaits() async {
        let startup = revealed(leaving: [.restoreDone, .visiblePageIdle])
        let references = StartupReferences(startup: startup, reveal: LaunchReveal(clock: ManualClock(), deadline: .seconds(60)))
        let page = Page()
        references.restored { [page] in StartupReferences.VisiblePage(page: page.state, loadsNothing: false) }
        #expect(startup.pendingReferences == [.visiblePageIdle], "restore is done")
        for _ in 0..<10 { await Task.yield() }
        #expect(startup.pendingReferences == [.visiblePageIdle], "a page whose first load has not started is not idle")

        page.start()
        for _ in 0..<10 { await Task.yield() }
        #expect(startup.phase == .revealed, "a loading page keeps startup from settling")
        page.finish()
        await reached(.settled, startup)
        #expect(startup.settleCause == .references)
    }

    /// The front page closes while it loads: the content change reads the front pane again, which
    /// shows no page; the wait ends without the failsafe (and without the page's deinit).
    @Test func aClosedLoadingPageEndsTheWaitOnTheContentChange() async {
        let startup = revealed(leaving: [.restoreDone, .visiblePageIdle])
        let references = StartupReferences(startup: startup, reveal: LaunchReveal(clock: ManualClock(), deadline: .seconds(60)))
        let front = Front()
        let page = Page()
        page.start()
        front.page = page
        references.restored { [front] in
            front.page.map { StartupReferences.VisiblePage(page: $0.state, loadsNothing: false) } ?? .idle
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(startup.phase == .revealed)

        front.page = nil
        references.noteContentChange()
        await reached(.settled, startup)
        #expect(startup.settleCause == .references)
        withExtendedLifetime(page) {}
    }

    @Test func aVisiblePageIsIdleOnlyOnceAFirstLoadEnded() {
        var machine = BrowserTabStateMachine()
        let id = BrowserNavigationID(rawValue: 1)
        #expect(StartupReferences.VisiblePage(page: machine.state, loadsNothing: false) == .waiting, "a new page's load has not started")
        #expect(StartupReferences.VisiblePage(page: machine.state, loadsNothing: true) == .idle, "a stand-in loads nothing")
        machine.apply(.started(id, url: URL(string: "https://example.com")))
        #expect(StartupReferences.VisiblePage(page: machine.state, loadsNothing: false) == .waiting)
        machine.apply(.stopped)
        #expect(StartupReferences.VisiblePage(page: machine.state, loadsNothing: false) == .idle, "a stopped load ended")
        machine.apply(.started(BrowserNavigationID(rawValue: 2), url: URL(string: "https://example.com/next")))
        #expect(StartupReferences.VisiblePage(page: machine.state, loadsNothing: false) == .idle, "only the first load counts")
    }

    @Test func noWindowInFrontShowsNoPage() {
        let services = AppServices(environment: AppEnvironment.current([:]), launchReveal: LaunchReveal(deadline: .seconds(60)))
        #expect(services.windows.visiblePageLoad() == .idle)
    }
}
