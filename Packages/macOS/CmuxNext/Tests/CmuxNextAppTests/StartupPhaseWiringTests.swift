import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// The startup phases wired to the app: `LaunchReveal`'s last produced region
/// reveals the launch, the daemon store's first snapshot and an unavailable daemon mark the settle
/// references, and the launch's windows give the visible panes their startup refs.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct StartupPhaseWiringTests {
    @MainActor private final class Count {
        var value = 0
    }

    /// The daemon's startup as `StartupReferences.watchUnavailable` reads it.
    @MainActor @Observable final class Daemon {  // not private: the macro's conformance extension must reach it
        var isUnavailable = false
    }

    /// The phase references still pending at each release.
    @MainActor private final class Pending {
        var sets: [Set<StartupPhase.Reference>] = []
    }

    private static func tree() -> DaemonTree {
        DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [])])
    }

    private func reached(_ phase: StartupPhase.Phase, _ startup: StartupPhase) async {
        await withCheckedContinuation { continuation in startup.whenReached(phase) { continuation.resume() } }
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
        let references = StartupReferences(startup: startup, reveal: reveal, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
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

    /// The unavailable daemon marks the phase first, then releases the pane refs: the last release
    /// is the daemon's, never the phase's settle.
    @Test func anUnavailableDaemonReleasesThePaneRefsAfterMarkingThePhase() async {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        startup.noteFirstFrame()
        let released = Pending()
        let refs = VisiblePaneRefs(hold: { _ in { _ in released.sets.append(startup.pendingReferences) } }, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                   phase: startup)
        let references = StartupReferences(startup: startup, reveal: LaunchReveal(clock: ManualClock(), deadline: .seconds(60)),
                                           mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                           paneRefs: refs)
        let daemon = Daemon()
        references.watchUnavailable { [daemon] in daemon.isUnavailable }
        daemon.isUnavailable = true
        await reached(.settled, startup)
        #expect(released.sets == [[]], "the restore ref ends once, after every phase reference")
        #expect(!refs.isHolding)
    }

    /// A browser tab's launch content signal: a first load that ended, or a process that ended.
    @Test func aBrowserPageLoadedOnlyOnceAFirstLoadEnded() {
        var machine = BrowserTabStateMachine()
        #expect(!machine.state.launchLoadEnded, "a new page's load has not started")
        machine.apply(.started(BrowserNavigationID(rawValue: 1), url: URL(string: "https://example.com")))
        #expect(!machine.state.launchLoadEnded)
        machine.apply(.stopped)
        #expect(machine.state.launchLoadEnded, "a stopped load ended")
        machine.apply(.started(BrowserNavigationID(rawValue: 2), url: URL(string: "https://example.com/next")))
        #expect(machine.state.launchLoadEnded, "only the first load counts")
    }

    /// Terminal content is a pane content signal while the refs hold startup: LaunchSettle's hook stays
    /// installed after the first content (which settles the launch) and goes at the first content after.
    @Test func theTerminalContentHookStaysWhileThePaneRefsHold() {
        let previous = TerminalTimings.onContentApplied
        defer { TerminalTimings.onContentApplied = previous }
        let refs = VisiblePaneRefs(hold: { _ in { _ in } }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let settle = LaunchSettle(reveal: LaunchReveal(clock: ManualClock(), deadline: .seconds(60)), paneRefs: refs)
        TerminalTimings.onContentApplied = { _ in }
        settle.terminalContentApplied()
        settle.terminalContentApplied()
        #expect(TerminalTimings.onContentApplied != nil, "the restore ref still holds: later content is a signal too")
        refs.daemonUnavailable()
        settle.terminalContentApplied()
        #expect(TerminalTimings.onContentApplied == nil, "no ref holds: the hook goes")
    }

    /// Native page content has nothing to load: it is loaded at once (a web page waits for its paint).
    @Test func aNativePageTabIsLoadedAtOnce() {
        let refs = VisiblePaneRefs(hold: { _ in { _ in } }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let native = InternalPageView(key: "local-page:settings:1", page: InternalPageID(rawValue: "settings"), content: NSView())
        #expect(refs.state(of: native) == .loadedIdle, "a native page has nothing to load")
    }

    /// The launch window shows the connecting view before the daemon answers: it holds startup as
    /// one loading stand-in, never as no window or no pane.
    @Test func theConnectingLaunchWindowHoldsStartupAsAStandIn() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), launchReveal: LaunchReveal(deadline: .seconds(60)))
        services.windows.ordersWindowsIn = false
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let refs = VisiblePaneRefs(hold: { _ in { _ in } }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        #expect(refs.windows(of: services.windows).isEmpty, "a window not ordered in and awaiting nothing is not shown")
        let id = try #require(services.windows.controllers.first).state.id
        services.windows.awaitingContent[id] = false
        let windows = refs.windows(of: services.windows)
        #expect(windows.map(\.panes) == [[VisiblePaneRefs.Pane(key: "window:\(id)", state: .loading)]],
                "a window kept off screen for its content stands in as one loading pane")
    }
}
