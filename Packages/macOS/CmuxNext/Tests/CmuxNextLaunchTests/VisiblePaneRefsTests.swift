import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// The restore's and the visible panes' startup refs (p08-startup task 013): every path releases
/// each ref exactly once, with its reason, on fake panes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VisiblePaneRefsTests {
    @Test func aLaunchWithNoWindowReleasesTheRestoreRefWithNoWindow() {
        let f = PaneRefsFixture()
        f.screen.panes = [Pane(key: "a", state: .loading)]
        f.refs.restoreFinished(showsWindow: false) { [screen = f.screen] in screen.panes }
        #expect(f.recorder.names == ["WindowManager.restore"], "no pane takes a ref without a window")
        #expect(f.recorder.releases == [["noWindow"]])
        #expect(!f.refs.isHolding)
        #expect(!f.bound.isScheduled)
    }

    @Test func windowsWithNoPaneReleaseTheRestoreRefWithNoVisiblePane() {
        let f = PaneRefsFixture()
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
        #expect(f.recorder.releases == [["noVisiblePane"]])
        #expect(!f.refs.isHolding)
        #expect(!f.bound.isScheduled)
    }

    @Test func eachPaneReleasesOnceWhenItsContentShows() async {
        let f = PaneRefsFixture()
        f.screen.panes = [Pane(key: "a", state: .loading), Pane(key: "b", state: .loading)]
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
        #expect(f.recorder.names == ["WindowManager.restore", "Startup.visiblePane", "Startup.visiblePane"])
        #expect(f.recorder.releases == [["restoreFinished"], [], []], "the pane refs are taken before the restore ref ends")
        #expect(f.refs.pendingPanes == ["a", "b"])
        #expect(f.bound.isScheduled)
        f.screen.panes = [Pane(key: "a", state: .loadedIdle), Pane(key: "b", state: .loading)]
        await f.recorder.released(count: 2)
        #expect(f.refs.pendingPanes == ["b"])
        // A second change for the same pane releases nothing again.
        f.screen.panes = [Pane(key: "a", state: .loadedIdle), Pane(key: "b", state: .loadedIdle)]
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
        f.screen.panes = [Pane(key: "a", state: .loadedIdle)]
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneLoadedIdle"]])
        #expect(f.recorder.lastReason == "visiblePaneLoadedIdle", "the completion reason is the pane's")
        #expect(!f.bound.isScheduled)
    }

    @Test func aNonObservableContentSignalIsReadOnNoteChange() async {
        let f = PaneRefsFixture()
        let terminal = TerminalContent()
        f.refs.restoreFinished(showsWindow: true) { [terminal] in [Pane(key: "t", state: terminal.hasContent ? .loadedIdle : .loading)] }
        terminal.hasContent = true
        f.refs.noteChange()
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneLoadedIdle"]])
    }

    @Test func aPaneThatNeverLoadsReleasesOnceAtTheBound() async throws {
        let f = PaneRefsFixture()
        f.screen.panes = [Pane(key: "a", state: .loading)]
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
        try await f.clock.waitForSleeper()
        f.clock.advance(by: VisiblePaneRefs.paneBound - .milliseconds(1))
        #expect(f.refs.pendingPanes == ["a"])
        f.clock.advance(by: .milliseconds(1))
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["visiblePaneTimedOut"]])
        // Its content showing later changes nothing.
        f.screen.panes = [Pane(key: "a", state: .loadedIdle)]
        f.refs.noteChange()
        #expect(!f.refs.isHolding)
        #expect(f.recorder.releases.allSatisfy { $0.count == 1 })
    }

    @Test func aPaneThatLeavesReleasesWithNoVisiblePaneAndANewOneTakesItsRef() async {
        let f = PaneRefsFixture()
        f.screen.panes = [Pane(key: "window:w1", state: .loading)]
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
        // The window's panes mount: the stand-in leaves after they took their refs.
        f.screen.panes = [Pane(key: "a", state: .loading)]
        await f.recorder.released(count: 2)
        #expect(f.recorder.releases == [["restoreFinished"], ["noVisiblePane"], []])
        #expect(f.refs.pendingPanes == ["a"])
        f.screen.panes = [Pane(key: "a", state: .loadedIdle)]
        await f.recorder.released(count: 3)
        #expect(f.recorder.lastReason == "visiblePaneLoadedIdle")
        #expect(!f.refs.isHolding)
    }

    @Test func anUnavailableDaemonBeforeTheRestoreReleasesTheRestoreRefOnce() {
        let f = PaneRefsFixture()
        f.refs.daemonUnavailable()
        #expect(f.recorder.releases == [["daemonUnavailable"]])
        f.screen.panes = [Pane(key: "a", state: .loading)]
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
        #expect(f.recorder.names == ["WindowManager.restore"], "no pane can load: none takes a ref")
        #expect(f.recorder.releases == [["daemonUnavailable"]])
        #expect(!f.refs.isHolding)
    }

    @Test func anUnavailableDaemonReleasesThePendingPanesOnceAndEndsTheBound() async {
        let f = PaneRefsFixture()
        let daemon = DaemonFlag()
        f.refs.watchUnavailable { [daemon] in daemon.isUnavailable }
        f.screen.panes = [Pane(key: "a", state: .loading), Pane(key: "b", state: .loadedIdle)]
        f.refs.restoreFinished(showsWindow: true) { [screen = f.screen] in screen.panes }
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

    @Test func aRestoreThatEndsTwiceReleasesOnce() {
        let f = PaneRefsFixture()
        f.refs.restoreFinished(showsWindow: false) { [] }
        f.refs.restoreFinished(showsWindow: true) { [Pane(key: "a", state: .loading)] }
        #expect(f.recorder.releases == [["noWindow"]])
        #expect(!f.refs.isHolding)
    }
}

private typealias Pane = VisiblePaneRefs.Pane

/// A pane refs object on a manual bound clock and a recording `hold`.
@MainActor
private final class PaneRefsFixture {
    let clock: ManualClock
    let recorder: RefRecorder
    let screen = FakeScreen()
    let bound: DemandTimer
    let refs: VisiblePaneRefs

    init() {
        let clock = ManualClock(), recorder = RefRecorder()
        let bound = DemandTimer(owner: "test.bound", clock: clock, ledger: WakeupLedger())
        self.clock = clock
        self.recorder = recorder
        self.bound = bound
        refs = VisiblePaneRefs(hold: { name in recorder.hold(name) }, bound: bound)
    }
}

/// Every ref taken, in order, with every release it got (a correct path gives each one release).
@MainActor
private final class RefRecorder {
    private(set) var names: [String] = []
    private(set) var releases: [[String]] = []
    private(set) var lastReason: String?
    private var waiters: [(count: Int, done: CheckedContinuation<Void, Never>)] = []

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

/// The panes a fake window shows (observable, as the app's mounts and page states are).
@MainActor @Observable
private final class FakeScreen {
    var panes: [Pane] = []
}

/// A content signal that is not observable (a terminal's first content).
@MainActor
private final class TerminalContent {
    var hasContent = false
}

@MainActor @Observable
private final class DaemonFlag {
    var isUnavailable = false
}
