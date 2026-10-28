import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The overlays, dialogs, toasts, tooltips, quit and window helpers of
/// CmuxNextDesign take their notices through the event fan-outs in the notice's own turn, their
/// hidden state from a node, and their deadlines and coalesced passes from the app's scheduler with
/// a class and an owner, instead of a raw observer plus a main-queue Task.
@MainActor
@Suite(.serialized) struct OverlayGroupSchedulerSweepTests {
    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: Dialogs

    /// A window's dialog ends with its cancel answer in the window's close notice, through the window's
    /// one WindowEvents observer (it waited one main-queue job), and its subscription goes with it.
    @Test func aWindowDialogEndsInItsWindowsCloseNotice() {
        let window = Self.window()
        let notices = NotificationCenter()
        let events = WindowEvents(window: window, center: notices)
        let center = CmuxDialogCenter(host: SweepDialogHost(), windowEvents: { _ in events })
        var answers: [CmuxDialogAnswer] = []
        center.present(CmuxDialogSpec(title: "Close?", buttons: [.cancel(), .ok()]), in: .window(window)) { answers.append($0) }
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 1)
        notices.post(name: NSWindow.willCloseNotification, object: window)
        #expect(answers.map(\.isDismissal) == [true], "the close notice did not end the dialog in its own turn")
        #expect(center.records.isEmpty)
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 0, "the answered dialog still follows its window")
        notices.post(name: NSWindow.willCloseNotification, object: window)
        #expect(answers.count == 1, "a second close answered the dialog again")
    }

    /// A tab dialog's watcher keeps the tab's hidden state in its node: an ancestor hiding (a tab switch)
    /// flips it once, and showing again flips it back; no hide walks ancestors.
    @Test func aTabDialogsWatcherFollowsItsTabThroughItsNode() throws {
        let window = Self.window()
        let content = try #require(window.contentView)
        let pane = NSView(frame: content.bounds)
        content.addSubview(pane)
        let tab = NSView(frame: pane.bounds)
        pane.addSubview(tab)
        let watcher = CmuxDialogScopeWatcher(watching: tab)
        var changes = 0
        watcher.onVisibilityChange = { changes += 1 }
        #expect(watcher.isShowing)
        pane.isHidden = true
        #expect(!watcher.node.isVisible, "the hidden tab's node stayed visible")
        #expect(!watcher.isShowing)
        #expect(changes == 1)
        pane.isHidden = false
        #expect(watcher.isShowing)
        #expect(changes == 2)
        watcher.stop()
    }

    /// A dialog presented over a tab that is already hidden starts hidden: its node reads AppKit's state once.
    @Test func aWatcherOnAHiddenTabStartsHidden() throws {
        let window = Self.window()
        let content = try #require(window.contentView)
        let tab = NSView(frame: content.bounds)
        content.addSubview(tab)
        tab.isHidden = true
        let watcher = CmuxDialogScopeWatcher(watching: tab)
        #expect(!watcher.isShowing, "a dialog over a hidden tab would show")
        tab.isHidden = false
        #expect(watcher.isShowing)
        watcher.stop()
    }

    // MARK: Popups

    /// A shown popup closes in the app's resign-active notice and in its window's resize notice, in that
    /// notice's own turn (a main-queue Task closed it one job later), and lets the subscriptions go.
    @Test func aPopupClosesInItsDismissNoticesOwnTurn() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let app = NotificationCenter(), windowNotices = NotificationCenter()
        let appEvents = AppEvents(center: app)
        let windowEvents = WindowEvents(window: window, center: windowNotices)
        var dismissed = 0
        let host = NativePopupHost(panel: NativePopupPanel(identifier: "test.sweep.popup"), input: events.tap)
        host.appEvents = appEvents
        host.windowEvents = { _ in windowEvents }
        host.onDismiss = { dismissed += 1 }
        let anchor = CGRect(x: window.frame.midX - 20, y: window.frame.midY, width: 40, height: 20)
        try #require(host.show(size: CGSize(width: 160, height: 100), anchor: anchor, in: window, entrance: false) != nil)
        #expect(appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 1)
        app.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(dismissed == 1, "the app going inactive did not close the popup in its notice's turn")
        #expect(!host.isShown)
        #expect(appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 0, "the closed popup still follows the app")

        try #require(host.show(size: CGSize(width: 160, height: 100), anchor: anchor, in: window, entrance: false) != nil)
        windowNotices.post(name: NSWindow.didResizeNotification, object: window)
        #expect(dismissed == 2, "its window's resize did not close the popup in the notice's turn")
        #expect(windowEvents.subscriberCount(NSWindow.didResizeNotification) == 0)
    }

    // MARK: Occlusion

    /// The occlusion checker's notices coalesce into one `visible` task on the app's scheduler, run on a
    /// later turn, never inside a notice (Chrome's performSelector:afterDelay:0); a pass run in between
    /// drops the posted one.
    @Test func theCheckersNoticesCoalesceIntoOneVisibleTask() {
        let turns = SweepTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { 1_000_000_000 }),
                                             performTurn: { turns.queue($0) }) { _ in SweepFakeLink() }
        let center = NotificationCenter(), workspace = NotificationCenter()
        let window = Self.window()
        let checker = WindowOcclusionChecker(windows: { [window] }, orderedWindows: { [window] },
                                             facts: { WindowOcclusionFacts(id: ObjectIdentifier($0), frame: CGRect(x: 0, y: 0, width: 10, height: 10)) },
                                             isAppHidden: { false }, drawsWhenOccluded: false, center: center,
                                             workspaceEvents: AppEvents(center: workspace), mainWork: work)
        checker.start()
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(checker.passes == 0, "a pass ran inside a window notice")
        #expect(work.postedCount(.visible) == 1, "the notices did not coalesce into one visible task")
        turns.runAll()
        #expect(checker.passes == 1)
        #expect(checker.isOffScreen(window), "the displays' sleep did not reach the pass")

        center.post(name: NSWindow.didResignMainNotification, object: window)
        checker.update()
        turns.runAll()
        #expect(checker.passes == 2, "the pass posted before an update ran as well")
        checker.stop()
    }

    // MARK: Deadlines

    /// On the app's deadline scheduler, a component's deadline is a MainDeadline with its owner and class.
    @Test func componentDeadlinesOnTheSchedulerAreClassedMainDeadlines() throws {
        let deadlines = ComponentDeadlines.on(MainDeadlineScheduler(work: MainWorkScheduler.still()))
        let toast = try #require(deadlines.deadline(owner: "toast", workClass: .visible) as? MainDeadline)
        #expect(toast.owner == "toast")
        #expect(toast.workClass == .visible)
        let quit = try #require(deadlines.deadline(owner: "quit.flush", workClass: .userBlocking) as? MainDeadline)
        #expect(quit.workClass == .userBlocking)
    }

    /// A quit save that outlives its limit answers timed out at the limit, and its write is not cancelled.
    @Test func aQuitSavePastItsLimitTimesOutAndKeepsWriting() async throws {
        let clock = ManualClock()
        let registry = QuitUnsavedRegistry(deadlines: .clock(clock))
        let slow = SweepParticipant()
        let save = Task { await registry.save([slow]) }
        try await clock.waitForSleeper()
        clock.advance(by: slow.quitFlushDeadline)
        let outcomes = await save.value
        #expect(outcomes.map(\.result) == [.timedOut])
        #expect(slow.writing, "the limit ended the write in progress, not only the wait")
        slow.finishWrite()
    }

    /// A save that answers first is saved, with no wait for its limit.
    @Test func aQuitSaveThatAnswersFirstIsSaved() async {
        let registry = QuitUnsavedRegistry(deadlines: .clock(ManualClock()))
        let quick = SweepParticipant(answersAtOnce: true)
        let outcomes = await registry.save([quick])
        #expect(outcomes.map(\.result) == [.saved])
    }
}

/// A dialog host that places nothing: the center's answers are what the tests read.
@MainActor
private final class SweepDialogHost: CmuxDialogHosting {
    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {}
    func hide(_ dialog: CmuxDialogView) {}
}

/// A document whose save waits for the test (or answers at once).
@MainActor
private final class SweepParticipant: QuitUnsavedParticipant {
    let answersAtOnce: Bool
    private(set) var writing = false
    private var write: CheckedContinuation<Void, Never>?

    init(answersAtOnce: Bool = false) {
        self.answersAtOnce = answersAtOnce
    }

    var quitParticipantID: String { "file:local:/tmp/p06-325.md" }
    var quitTitle: String { "p06-325.md" }
    var hasUnsavedChanges: Bool { true }
    var quitFlushDeadline: Duration { .seconds(2) }

    func flushForQuit() async throws {
        guard !answersAtOnce else { return }
        writing = true
        await withCheckedContinuation { write = $0 }
        writing = false
    }

    func discardForQuit() async {}

    func finishWrite() {
        write?.resume()
        write = nil
    }
}

/// The turns a scheduler queued, run when the test says.
@MainActor
private final class SweepTurns {
    private var pending: [@MainActor () -> Void] = []

    func queue(_ turn: @escaping @MainActor () -> Void) { pending.append(turn) }

    func runAll() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

@MainActor
private final class SweepFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
