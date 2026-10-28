import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextBrowserAutomation
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import WebKit

/// The driver's observers run in the automation class: `dialog.opened`
/// (DialogBroker) and `tab.crashed` (TabWatcher) are sent by an automation task on the injected
/// scheduler, after the person's pending input, once per change, and never after the watch ends.
/// Frames and turns fire by hand, so nothing here waits on a clock or the main run loop.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AutomationObserverTests {
    @Test func aNewPromptEmitsDialogOpenedOnceAfterThePersonsPendingInput() {
        let rig = ObserverRig()
        let tab = rig.tab()
        var events: [String] = []
        let broker = DialogBroker(work: rig.work) { name, _ in events.append(name) }
        broker.watch(tab)
        #expect(events.isEmpty, "a tab with no prompt emitted")

        rig.input.pending = true
        tab.enqueuePrompt(.alert(message: "hello"), origin: "https://example.com") { _ in }
        rig.frame()
        #expect(events.isEmpty, "dialog.opened went ahead of the person's pending key")
        rig.input.pending = false
        rig.frame()
        #expect(events == ["dialog.opened"])
        rig.frame()
        #expect(events == ["dialog.opened"], "one prompt emitted twice")

        broker.stopWatching(tab.id)
        tab.enqueuePrompt(.confirm(message: "again"), origin: "https://example.com") { _ in }
        _ = rig.turns.runAll()
        rig.frame()
        #expect(events == ["dialog.opened"], "a prompt after stopWatching emitted")
        rig.stop()
    }

    @Test func aProcessExitEmitsTabCrashedOnceAndFailsTheWaits() async throws {
        let rig = ObserverRig()
        let tab = rig.tab()
        // An exit from before the watch is not news.
        tab.apply(.processExited(BrowserProcessExit(reason: .crashed)))
        let driver = WebKitDriver(provider: ObserverTabs(), mainWork: rig.work)
        let session = TabSession(tabID: tab.id, driver: driver)
        var events: [String] = []
        let watcher = TabWatcher(tab: tab, session: session, work: rig.work) { name, _ in events.append(name) }
        rig.frame()
        #expect(events.isEmpty, "the exit from before the watch emitted tab.crashed")

        // A wait on a navigation the engine never starts: only failAll ends it.
        let waits = session.waits
        let ticket = waits.beginNavigation { BrowserNavigationID(rawValue: 99) }
        let wait = Task { () async -> DriverError? in
            do throws(DriverError) {
                try await waits.reach(.load, for: ticket, timeout: nil, what: "test")
                return nil
            } catch {
                return error
            }
        }
        // The task registers its wait in its first run (the main executor runs jobs in order).
        await Task.yield()
        try #require(waits.pendingCount == 1)

        rig.input.pending = true
        tab.apply(.processExited(BrowserProcessExit(reason: .killed)))
        rig.frame()
        #expect(events.isEmpty, "tab.crashed went ahead of the person's pending key")
        rig.input.pending = false
        rig.frame()
        #expect(events == ["tab.crashed"])
        #expect(waits.pendingCount == 0, "the crash did not fail the waits")
        #expect(await wait.value?.code == .closed)
        rig.frame()
        #expect(events == ["tab.crashed"], "one exit emitted twice")

        watcher.stop()
        tab.apply(.started(BrowserNavigationID(rawValue: 1), url: URL(string: "https://example.com/")))
        tab.apply(.processExited(BrowserProcessExit(reason: .crashed)))
        _ = rig.turns.runAll()
        rig.frame()
        #expect(events == ["tab.crashed"], "an exit after stop() emitted")
        withExtendedLifetime(driver) {}
        rig.stop()
    }

    /// A load wait's timeout is an automation-class MainDeadline on the driver's scheduler (it
    /// was a DemandTimer whose fire started an unclassed main-actor Task): when it comes while the person has input
    /// pending, the agent's timeout waits behind it, then fails the wait once.
    @Test func aLoadWaitsTimeoutIsAnAutomationTaskBehindThePersonsInput() async throws {
        let rig = ObserverRig()
        let tab = rig.tab()
        let driver = WebKitDriver(provider: ObserverTabs(), mainWork: rig.work)
        let session = TabSession(tabID: tab.id, driver: driver)
        let waits = session.waits
        let ticket = waits.beginNavigation { BrowserNavigationID(rawValue: 7) }
        rig.input.pending = true
        let wait = Task { () async -> DriverError? in
            do throws(DriverError) {
                try await waits.reach(.load, for: ticket, timeout: .milliseconds(20), what: "page.goto")
                return nil
            } catch {
                return error
            }
        }
        await Task.yield()
        try #require(waits.pendingCount == 1)

        // The deadline's wake is the main thread's wake-up queue (real uptime); its action is an automation post.
        let deadline = ContinuousClock.now + .seconds(10)
        while rig.work.postedCount(.automation) == 0, ContinuousClock.now < deadline {
            // wakeup-allow: a test's bounded wait for the 20 ms deadline's wake on the main run loop
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(rig.work.postedCount(.automation) == 1, "the timeout was not posted in the automation class")
        rig.frame()
        #expect(waits.pendingCount == 1, "the agent's timeout ran ahead of the person's pending input")

        rig.input.pending = false
        rig.frame()
        #expect(waits.pendingCount == 0)
        #expect(await wait.value?.code == .timeout)
        withExtendedLifetime(driver) {}
        rig.stop()
    }
}

/// A scheduler on a fake link kept up, with fake input, a clock and run loop turns the test moves,
/// and a WebKit engine for real tabs.
@MainActor
private final class ObserverRig {
    let input: ObserverInput
    let turns: ObserverTurns
    let work: MainWorkScheduler
    private let clock: ObserverUptime
    private let keeper: FrameClient
    private let engine: WebKitEngine
    private var timestamp: CFTimeInterval = 0

    init() {
        _ = NSApplication.shared
        let input = ObserverInput(), turns = ObserverTurns(), clock = ObserverUptime()
        self.input = input
        self.turns = turns
        self.clock = clock
        engine = WebKitEngine(fileInput: ObserverFileInput(), stores: .inMemory())
        // The stall clock never moves: frames fire only by hand.
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read), clock: ManualClock(),
                                         performTurn: turns.perform) { _ in ObserverLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    func tab() -> WebKitTab { engine.makeWebKitTab() }

    /// One display frame, one refresh period after the last.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() { keeper.deactivate() }
}

/// The scheduler's run loop turns, run only when the test says.
@MainActor
private final class ObserverTurns {
    private var queued: [@MainActor () -> Void] = []

    var perform: MainWorkScheduler.TurnPerformer { { [weak self] turn in self?.queued.append(turn) } }

    /// Runs the turns queued now; returns how many ran.
    func runAll() -> Int {
        let turns = queued
        queued.removeAll()
        for turn in turns { turn() }
        return turns.count
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ObserverUptime {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class ObserverInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class ObserverLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// Pages here never pick a file.
@MainActor
private final class ObserverFileInput: WebFileInputAnswering {
    func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                         completion: @escaping @MainActor ([URL]?) -> Void) {
        completion(nil)
    }
}

/// An App with no tabs: the driver here only owns the session.
@MainActor
private final class ObserverTabs: AutomationTabProvider {
    func automationTabs(all: Bool) -> [AutomationTab] { [] }
    func openAutomationTab(url: URL?) async throws -> WebKitTab { throw ObserverTabsError.none }
    func closeAutomationTab(_ id: BrowserTabID) {}
    func endSessionTab(_ id: String) async -> Bool { false }
    func activateAutomationTab(_ id: BrowserTabID) {}
}

private enum ObserverTabsError: Error {
    /// The fake opens no tab.
    case none
}
