import AppKit
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// The restore's and the visible panes' startup refs (p08-startup task 013): every path releases
/// each ref exactly once, with its reason, on fake windows and panes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VisiblePaneRefsTests {
    @Test func aLaunchWithNoWindowReleasesTheRestoreRefWithNoWindow() {
        let f = PaneRefsFixture()
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.names == ["WindowManager.restore"], "no pane takes a ref without a window")
        #expect(f.recorder.releases == [["noWindow"]])
        #expect(!f.refs.isHolding)
        #expect(!f.bound.isScheduled)
    }

    @Test func windowsWithNoPaneReleaseTheRestoreRefWithNoVisiblePane() {
        let f = PaneRefsFixture()
        f.screen.show([])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.releases == [["noVisiblePane"]])
        #expect(!f.refs.isHolding)
        #expect(!f.bound.isScheduled)
    }

    @Test func eachPaneReleasesOnceWhenItsContentShows() async {
        let f = PaneRefsFixture()
        f.screen.show([Pane(key: "a", state: .loading), Pane(key: "b", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.names == ["WindowManager.restore", "Startup.visiblePane", "Startup.visiblePane"])
        #expect(f.recorder.releases == [["restoreFinished"], [], []], "the pane refs are taken before the restore ref ends")
        #expect(f.refs.pendingPanes == ["a", "b"])
        #expect(f.bound.isScheduled)
        f.screen.show([Pane(key: "a", state: .loadedIdle), Pane(key: "b", state: .loading)])
        await f.recorder.released(count: 2)
        #expect(f.refs.pendingPanes == ["b"])
        // A second change for the same pane releases nothing again.
        f.screen.show([Pane(key: "a", state: .loadedIdle), Pane(key: "b", state: .loadedIdle)])
        await f.recorder.released(count: 3)
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneLoadedIdle"], ["visiblePaneLoadedIdle"]])
        #expect(f.recorder.lastReason == "visiblePaneLoadedIdle")
        #expect(!f.refs.isHolding)
        #expect(!f.bound.isScheduled, "the bound ends with the last pane")
        f.refs.noteChange()
        f.refs.daemonUnavailable()
        #expect(f.recorder.releases.allSatisfy { $0.count == 1 })
    }

    @Test func aPaneLoadedAtTheEndOfRestoreReleasesAfterTheRestoreRef() {
        let f = PaneRefsFixture()
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneLoadedIdle"]])
        #expect(f.recorder.lastReason == "visiblePaneLoadedIdle", "the completion reason is the pane's")
        #expect(!f.bound.isScheduled)
    }

    @Test func aNonObservableContentSignalIsReadOnNoteChange() async {
        let f = PaneRefsFixture()
        let terminal = TerminalContent()
        f.refs.restoreFinished { [terminal] in
            [Window(id: "w", content: .workspace(onScreen: [Pane(key: "t", state: terminal.hasContent ? .loadedIdle : .loading)], layoutPanes: 1))]
        }
        terminal.hasContent = true
        f.refs.noteChange()
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneLoadedIdle"]])
    }

    @Test func aPaneThatNeverLoadsReleasesOnceAtTheBound() async throws {
        let f = PaneRefsFixture()
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        try await f.clock.waitForSleeper()
        f.clock.advance(by: VisiblePaneRefs.paneBound - .milliseconds(1))
        #expect(f.refs.pendingPanes == ["a"])
        f.clock.advance(by: .milliseconds(1))
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneTimedOut"]])
        // Its content showing later changes nothing.
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        f.refs.noteChange()
        #expect(!f.refs.isHolding)
        #expect(f.recorder.releases.allSatisfy { $0.count == 1 })
    }

    @Test func aPaneThatLeavesReleasesWithNoVisiblePaneAndANewOneTakesItsRef() async {
        let f = PaneRefsFixture()
        f.screen.windows = [Window(id: "w1", content: .workspace(onScreen: [], layoutPanes: 2))]
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.refs.pendingPanes == ["window:w1"], "a window whose panes are not mounted stands in as one pane")
        // The window's panes mount: the stand-in leaves after they took their refs.
        f.screen.show([Pane(key: "a", state: .loading)])
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["noVisiblePane"], []])
        #expect(f.refs.pendingPanes == ["a"])
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        await f.recorder.released(count: 3)
        #expect(f.recorder.lastReason == "visiblePaneLoadedIdle")
        #expect(!f.refs.isHolding)
    }

    /// The connecting view, a parked workspace, a window kept off screen for its content: each holds
    /// startup until what it shows appears, so the restore never ends with no visible pane.
    @Test func aWindowWithNothingInstalledHoldsStartupUntilItsPageShows() async {
        let f = PaneRefsFixture()
        f.screen.windows = [Window(id: "w1", content: .loading)]
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.releases == [["restoreFinished"], []])
        #expect(f.refs.pendingPanes == ["window:w1"])
        f.screen.windows = [Window(id: "w1", content: .page(Pane(key: "window:w1:settings", state: .loading)))]
        await f.recorder.released(count: 2)
        #expect(f.refs.pendingPanes == ["window:w1:settings"], "a top page holds startup by its own key")
        f.screen.windows = [Window(id: "w1", content: .page(Pane(key: "window:w1:settings", state: .loadedIdle)))]
        await f.recorder.released(count: 3)
        #expect(f.recorder.lastReason == "visiblePaneLoadedIdle")
    }

    @Test func aWindowStandsInOnlyWhileNothingOfItShows() {
        let loading = Pane(key: "a", state: .loading)
        #expect(Window(id: "w", content: .loading).panes == [Pane(key: "window:w", state: .loading)])
        #expect(Window(id: "w", content: .workspace(onScreen: [], layoutPanes: 1)).panes == [Pane(key: "window:w", state: .loading)])
        #expect(Window(id: "w", content: .workspace(onScreen: [], layoutPanes: 0)).panes.isEmpty, "a workspace with no pane shows none")
        #expect(Window(id: "w", content: .workspace(onScreen: [loading], layoutPanes: 3)).panes == [loading])
        #expect(Window(id: "w", content: .page(loading)).panes == [loading])
    }

    @Test func anUnavailableDaemonBeforeTheRestoreReleasesTheRestoreRefOnce() {
        let f = PaneRefsFixture()
        f.refs.daemonUnavailable()
        #expect(f.recorder.releases == [["daemonUnavailable"]])
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.names == ["WindowManager.restore"], "no pane can load: none takes a ref")
        #expect(f.recorder.releases == [["daemonUnavailable"]])
        #expect(!f.refs.isHolding)
    }

    @Test func anUnavailableDaemonReleasesThePendingPanesOnceAndEndsTheBound() async {
        let f = PaneRefsFixture()
        let daemon = DaemonFlag()
        f.refs.watchUnavailable { [daemon] in daemon.isUnavailable }
        f.screen.show([Pane(key: "a", state: .loading), Pane(key: "b", state: .loadedIdle)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.releases == [["restoreFinished"], [], ["visiblePaneLoadedIdle"]])
        daemon.isUnavailable = true
        await f.recorder.released(count: 3)
        #expect(f.recorder.releases == [["restoreFinished"], ["daemonUnavailable"], ["visiblePaneLoadedIdle"]])
        #expect(f.recorder.lastReason == "daemonUnavailable")
        #expect(!f.bound.isScheduled)
        f.clock.advance(by: VisiblePaneRefs.paneBound)
        f.refs.daemonUnavailable()
        #expect(f.recorder.releases.allSatisfy { $0.count == 1 })
    }

    /// p01-process-152 (bench_launch.py after-kill): `launch.visible_panes_shown` is the moment every pane on screen
    /// was handed its content (the app then waits for the terminals' frames: LaunchTerminalsDrawnTests). It comes once,
    /// before the last pane's release, and only when that pane loaded.
    @Test func shownRunsOnceWhenTheLastVisiblePaneLoads() async {
        let f = PaneRefsFixture()
        f.screen.show([Pane(key: "a", state: .loading), Pane(key: "b", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        f.screen.show([Pane(key: "a", state: .loadedIdle), Pane(key: "b", state: .loading)])
        await f.recorder.released(count: 2)
        #expect(f.shownAt.isEmpty, "one pane still loads")
        f.screen.show([Pane(key: "a", state: .loadedIdle), Pane(key: "b", state: .loadedIdle)])
        await f.recorder.released(count: 3)
        #expect(f.shownAt == [2], "shown runs before the last pane's release")
        f.refs.noteChange()
        f.refs.daemonUnavailable()
        #expect(f.shownAt == [2])
    }

    @Test func shownRunsWhenEveryPaneLoadedAtTheEndOfRestore() {
        let f = PaneRefsFixture()
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.shownAt == [1], "after the restore ref, before the pane's")
    }

    @Test func shownNeverRunsWhenTheBoundEndsThePanes() async throws {
        let f = PaneRefsFixture()
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        try await f.clock.waitForSleeper()
        f.clock.advance(by: VisiblePaneRefs.paneBound)
        await f.recorder.released(count: 2)
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        f.refs.noteChange()
        for _ in 0..<10 { await Task.yield() }
        #expect(f.shownAt.isEmpty, "a pane that timed out did not show its content in time")
    }

    @Test func shownNeverRunsWhenTheDaemonIsUnavailableOrNoPaneShows() {
        let unavailable = PaneRefsFixture()
        unavailable.screen.show([Pane(key: "a", state: .loading)])
        unavailable.refs.restoreFinished { [screen = unavailable.screen] in screen.windows }
        unavailable.refs.daemonUnavailable()
        #expect(unavailable.shownAt.isEmpty)
        let empty = PaneRefsFixture()
        empty.screen.show([])
        empty.refs.restoreFinished { [screen = empty.screen] in screen.windows }
        #expect(empty.shownAt.isEmpty, "no pane on screen showed anything")
    }

    @Test func aRestoreThatEndsTwiceReleasesOnce() {
        let f = PaneRefsFixture()
        f.refs.restoreFinished { [] }
        f.refs.restoreFinished { [Window(id: "w", content: .loading)] }
        #expect(f.recorder.releases == [["noWindow"]])
        #expect(!f.refs.isHolding)
    }

    /// A page's first paint is not observable: `follow` subscribes once per page, and the paint reads
    /// the panes again.
    @Test func aFollowedPaintReadsThePanesAgainAndSubscribesOnce() async {
        let f = PaneRefsFixture()
        let page = PaintSignal()
        f.refs.restoreFinished { [refs = f.refs, page] in
            refs.follow(page) { page.whenPainted($0) }
            return [Window(id: "w", content: .page(Pane(key: "p", state: page.painted ? .loadedIdle : .loading)))]
        }
        #expect(page.waiters.count == 1)
        f.refs.noteChange()
        for _ in 0..<10 { await Task.yield() }
        #expect(page.waiters.count == 1, "a page is followed once, however often it is read")
        page.paint()
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneLoadedIdle"]])
    }

    /// Only a pane in a window and not hidden is on screen; a window not ordered in is not.
    @Test func onlyMountedShownPanesAndOrderedInWindowsAreOnScreen() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = NSView()
        #expect(!Window.isOnScreen(pane), "a pane in no window is not on screen")
        window.contentView?.addSubview(pane)
        #expect(Window.isOnScreen(pane))
        pane.isHidden = true
        #expect(!Window.isOnScreen(pane), "a hidden pane is not on screen")
        #expect(!Window.isOnScreen(window), "a window not ordered in")
        #expect(!Window.isOnScreen(nil as NSWindow?))
    }

    /// A window's occlusion change reads the panes again (it is not observable), and the window's
    /// observers go with the last ref.
    @Test func aWindowVisibilityChangeReadsThePanesAgainUntilNoRefIsHeld() async {
        _ = NSApplication.shared
        let f = PaneRefsFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shown = TerminalContent()
        f.refs.restoreFinished { [shown] in
            [Window(id: "w", content: .workspace(onScreen: shown.hasContent ? [] : [Pane(key: "a", state: .loading)], layoutPanes: 0))]
        }
        let center = NotificationCenter()
        f.refs.followWindows([window], center: center)
        let occlusion = NSWindow.didChangeOcclusionStateNotification
        let events = WindowEvents.of(window, center: center)
        #expect(events.subscriberCount(occlusion) == 1)
        shown.hasContent = true  // the pane's window went off screen
        center.post(name: occlusion, object: window)
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["noVisiblePane"]])
        #expect(events.subscriberCount(occlusion) == 0, "the observers end with the last ref")
    }

    /// The phase's restore and visible-page references are marked before the release that ends them,
    /// so the phase never settles after the last ref.
    @Test func thePhaseReferencesAreMarkedBeforeTheirRelease() async {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        phase.noteFirstFrame()
        phase.markDone(.firstSnapshot)
        let f = PaneRefsFixture(phase: phase)
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.recorder.pendingAtRelease == [[.visiblePageIdle]], "restore done before the restore ref ends")
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        await f.recorder.released(count: 2)
        #expect(f.recorder.pendingAtRelease == [[.visiblePageIdle], []], "the page reference is done before the last ref ends")
        #expect(phase.phase == .settled)
    }
}

/// The refs on the launch's real scheduler and phase: the completion reason each path records.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VisiblePaneRefsCompletionTests {
    @Test func loadedPanesCompleteStartupAsLoadedIdle() async {
        let f = CompletionFixture()
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        #expect(f.startup.completion == nil)
        f.screen.show([Pane(key: "a", state: .loadedIdle)])
        #expect(await f.completion().reason == .visiblePaneLoadedIdle)
    }

    @Test func aPaneThatNeverLoadsCompletesStartupAsTimedOut() async throws {
        let f = CompletionFixture()
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        try await f.boundClock.waitForSleeper()
        f.boundClock.advance(by: VisiblePaneRefs.paneBound)
        #expect(await f.completion().reason == .visiblePaneTimedOut)
    }

    @Test func aLaunchWithNoWindowCompletesAsNoWindow() async {
        let f = CompletionFixture()
        f.refs.restoreFinished { [] }
        #expect(await f.completion().reason == .noWindow)
    }

    @Test func anUnavailableDaemonCompletesAsDaemonUnavailable() async {
        let f = CompletionFixture()
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        f.refs.daemonUnavailable()
        #expect(await f.completion().reason == .daemonUnavailable)
    }

    @Test func aRefStillHeldAtTheFailsafeCompletesAsFailsafe() async throws {
        let f = CompletionFixture(revealed: false)
        f.screen.show([Pane(key: "a", state: .loading)])
        f.refs.restoreFinished { [screen = f.screen] in screen.windows }
        // No first frame: the reveal deadline, then the phase's settle failsafe.
        try await f.phaseClock.waitForSleeper()
        f.phaseClock.advance(by: .milliseconds(1_500))
        try await f.phaseClock.waitForSleeper()
        f.phaseClock.advance(by: .milliseconds(8_500))
        #expect(await f.completion().reason == .failsafe)
    }
}

private typealias Pane = VisiblePaneRefs.Pane
private typealias Window = VisiblePaneRefs.Window

/// A pane refs object on a manual bound clock and a recording `hold`.
@MainActor
private final class PaneRefsFixture {
    let clock: ManualClock
    let recorder: RefRecorder
    let screen = FakeScreen()
    let bound: DemandTimer
    let refs: VisiblePaneRefs

    /// Each run of `shown`: how many releases were recorded when it ran.
    private let shown: ShownRecorder
    var shownAt: [Int] { shown.releaseCounts }

    init(phase: StartupPhase? = nil) {
        let clock = ManualClock(), recorder = RefRecorder(phase: phase), shown = ShownRecorder()
        let bound = DemandTimer(owner: "test.bound", clock: clock, ledger: WakeupLedger())
        self.clock = clock
        self.recorder = recorder
        self.bound = bound
        self.shown = shown
        refs = VisiblePaneRefs(hold: { name in recorder.hold(name) }, mainWork: MainWorkScheduler(budget: MainFrameBudget()), phase: phase, bound: bound)
        refs.whenShown { [shown] in shown.releaseCounts.append(recorder.releaseCount) }
    }
}

/// The runs of a ``VisiblePaneRefs`` `shown` closure.
@MainActor
private final class ShownRecorder {
    var releaseCounts: [Int] = []
}

/// The refs on a real ``StartupScheduler`` whose launch phase is `phase`: registration and the first
/// frame are done, so the restore and pane refs decide the completion.
@MainActor
private final class CompletionFixture {
    let phaseClock: ManualClock
    let boundClock: ManualClock
    let screen = FakeScreen()
    let startup: StartupScheduler
    let refs: VisiblePaneRefs

    /// - Parameter revealed: Whether the first frame came (else the reveal deadline and the failsafe decide).
    init(revealed: Bool = true) {
        let phaseClock = ManualClock(), boundClock = ManualClock()
        let phase = StartupPhase(clock: phaseClock, ledger: WakeupLedger())
        let mainWork = MainWorkScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), startup: phase) { _ in TestLink() }
        let startup = StartupScheduler(mainWork: mainWork, background: BackgroundWork(label: "test.visible-pane-refs"),
                                       clock: ManualClock(), ledger: WakeupLedger(), log: StartupTaskLog())
        self.phaseClock = phaseClock
        self.boundClock = boundClock
        self.startup = startup
        refs = VisiblePaneRefs(startup: startup, mainWork: mainWork, phase: phase,
                               bound: DemandTimer(owner: "test.bound", clock: boundClock, ledger: WakeupLedger()))
        if revealed { phase.noteFirstFrame() }
        phase.markDone(.firstSnapshot)
        startup.finishRegistration()
        startup.firstFrameCommitted()
    }

    func completion() async -> StartupScheduler.Completion {
        await withCheckedContinuation { continuation in startup.whenComplete { continuation.resume(returning: $0) } }
    }
}

/// Every ref taken, in order, with every release it got (a correct path gives each one release).
@MainActor
private final class RefRecorder {
    private(set) var names: [String] = []
    private(set) var releases: [[String]] = []
    private(set) var lastReason: String?
    /// The phase's references still pending at each release, in release order.
    private(set) var pendingAtRelease: [Set<StartupPhase.Reference>] = []
    private let phase: StartupPhase?
    private var waiters: [(count: Int, done: CheckedContinuation<Void, Never>)] = []

    init(phase: StartupPhase?) {
        self.phase = phase
    }

    var releaseCount: Int { releases.reduce(0) { $0 + $1.count } }

    func hold(_ name: StaticString) -> VisiblePaneRefs.Release {
        let index = names.count
        names.append(name.description)
        releases.append([])
        return { [weak self] reason in self?.release(index, reason) }
    }

    private func release(_ index: Int, _ reason: StartupInProgressRef.Reason) {
        releases[index].append(reason.rawValue)
        lastReason = reason.rawValue
        if let phase { pendingAtRelease.append(phase.pendingReferences) }
        let count = releaseCount
        let ready = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        for waiter in ready { waiter.done.resume() }
    }

    /// Returns once `count` releases were recorded in all.
    func released(count: Int) async {
        guard releaseCount < count else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in waiters.append((count, done)) }
    }
}

/// The windows a fake launch shows (observable, as the app's mounts and page states are).
@MainActor @Observable
private final class FakeScreen {
    var windows: [Window] = []

    /// One window showing `panes` on screen.
    func show(_ panes: [Pane]) {
        windows = [Window(id: "w", content: .workspace(onScreen: panes, layoutPanes: panes.count))]
    }
}

/// A content signal that is not observable (a terminal's first content).
@MainActor
private final class TerminalContent {
    var hasContent = false
}

/// A one-shot paint signal, as `PageWebView.whenPainted` gives.
@MainActor
private final class PaintSignal {
    private(set) var painted = false
    private(set) var waiters: [() -> Void] = []

    func whenPainted(_ body: @escaping () -> Void) {
        if painted { body() } else { waiters.append(body) }
    }

    func paint() {
        painted = true
        let ready = waiters
        waiters = []
        for body in ready { body() }
    }
}

@MainActor @Observable
private final class DaemonFlag {
    var isUnavailable = false
}

private final class TestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
