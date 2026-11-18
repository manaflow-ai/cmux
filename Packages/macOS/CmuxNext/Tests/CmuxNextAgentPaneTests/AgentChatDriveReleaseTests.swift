import AppKit
@testable import CmuxNextAgentPane
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

/// `agent.chat.drive` hands the pointer back to the person: its hold watches for them every
/// ``DriveWatch/step`` (type-only runs too, which are all hold), and its release counts only once
/// the pointer-leave went in. A failed release leaves the backstop armed for a later path or the timer.
@MainActor
@Suite(.closesItsWindows, .timeLimit(.minutes(1)))
struct AgentChatDriveReleaseTests {
    @Test func theHoldStopsAsSoonAsThePersonIsBack() async throws {
        var checks = 0
        let started = ContinuousClock.now
        let back = try await DriveWatch.watch(until: started + .seconds(10), step: .milliseconds(10)) {
            checks += 1
            return checks == 3
        }
        #expect(back)
        #expect(checks == 3)
        #expect(ContinuousClock.now - started < .seconds(5), "the hold slept on after the person came back")
    }

    @Test func aHoldWithNobodyBackRunsOutAndChecksBetweenSteps() async throws {
        var checks = 0
        let started = ContinuousClock.now
        let back = try await DriveWatch.watch(until: started + .milliseconds(300), step: .milliseconds(50)) {
            checks += 1
            return false
        }
        #expect(!back)
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(checks >= 4, "only \(checks) checks in a 300 ms hold of 50 ms steps")
    }

    @Test func theDefaultStepIsAtMostAHundredMilliseconds() {
        #expect(DriveWatch.step <= .milliseconds(100))
    }

    typealias Outcome = AgentChatDriveInput.ReleaseOutcome

    /// A send that answers `answers` in turn (then `.wentIn`), and the waits a round made.
    final class Sends {
        var answers: [Outcome]
        var count = 0
        var waits: [Duration] = []
        /// Runs at each wait of a round, after which the round yields (a trigger's task gets its turn).
        var onWait: ((Int) -> Void)?

        init(_ answers: [Outcome] = []) {
            self.answers = answers
        }

        /// `later`: the later rounds' schedule (none unless a test asks: the app's are seconds apart).
        func release(armed: Bool = true, later: [Duration] = []) -> DriveRelease {
            let release = DriveRelease(send: { [self] in
                count += 1
                return answers.isEmpty ? .wentIn : answers.removeFirst()
            }, sleep: { [self] in
                waits.append($0)
                onWait?(waits.count)
                await Task.yield()
            }, later: later)
            release.armed = armed
            return release
        }
    }

    /// Waits (bounded) for a release a trigger started in its own task.
    func settled(_ release: DriveRelease) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !release.released, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func nothingHeldIsReleasedWithoutAnEvent() async {
        let sends = Sends()
        let release = sends.release(armed: false)
        await release.release("end")
        #expect(release.released && release.how == "end")
        #expect(sends.count == 0)
    }

    @Test func aFailingSendIsRetriedUntilItGoesIn() async {
        let sends = Sends([.failed, .failed, .failed])
        let release = sends.release()
        release.armBackstop(after: .seconds(60))
        await release.release("end")
        #expect(release.released && release.how == "end")
        #expect(sends.count == 4)
        #expect(sends.waits == [.milliseconds(50), .milliseconds(100), .milliseconds(200)])
        #expect(!release.isBackstopArmed)
        // Once released, no path sends again.
        await release.release("timer")
        #expect(release.how == "end" && sends.count == 4)
    }

    @Test func theRetriesAreCappedAtAboutFiveSeconds() {
        #expect(DriveRelease.retryWaits.count + 1 <= 10)
        #expect(DriveRelease.retryWaits.reduce(.zero, +) <= .seconds(5))
        #expect(DriveRelease.retryWaits.allSatisfy { $0 <= .seconds(1) })
    }

    @Test func aViewThatIsGoneHoldsNoHover() async {
        let sends = Sends([.gone])
        let release = sends.release()
        await release.release("end")
        #expect(release.released && release.how == "teardown")
        #expect(sends.count == 1)
    }

    @Test func overTheCapTheReleaseStaysPendingUntilTheNextTrigger() async throws {
        let sends = Sends(Array(repeating: .failed, count: DriveRelease.retryWaits.count + 1))
        let release = sends.release()
        release.armBackstop(after: .seconds(60))
        await release.release("end")
        #expect(!release.released && release.how == nil, "a release that never went in is pending")
        #expect(release.isBackstopArmed)
        #expect(sends.count == DriveRelease.retryWaits.count + 1)
        release.runEnded = true
        release.trigger("window")
        try await settled(release)
        #expect(release.released && release.how == "window")
    }

    @Test func concurrentReleasesSendOneAtATimeAndAllSeeTheEnd() async {
        var inFlight = 0, most = 0, count = 0
        let release = DriveRelease(send: {
            count += 1
            inFlight += 1
            most = max(most, inFlight)
            for _ in 0..<5 { await Task.yield() }
            inFlight -= 1
            return count < 3 ? .failed : .wentIn
        }, sleep: { _ in await Task.yield() })
        release.armed = true
        async let first: Void = release.release("end")
        async let second: Void = release.release("person")
        async let third: Void = release.release("timer")
        _ = await (first, second, third)
        #expect(most == 1, "two sends were in flight at once")
        #expect(count == 3)
        // The calls start in any order: the first one's round is the one that went in, the others joined it.
        #expect(release.released && ["end", "person", "timer"].contains(release.how ?? ""))
    }

    /// The tab closing, its window closing and the app resigning active each release at once, and a
    /// run still going is told which (`interrupted`).
    @Test(arguments: ["teardown", "window_close", "resign", "detached"])
    func eachTriggerReleasesAndInterruptsTheRun(_ trigger: String) async throws {
        let release = Sends([.failed]).release()
        release.trigger(trigger)
        #expect(release.triggered == trigger)
        try await settled(release)
        #expect(release.released && release.how == trigger)
        // Released: a later trigger changes nothing.
        release.trigger("resign")
        #expect(release.how == trigger && release.triggered == trigger)
    }

    /// The run reads its window and the app with the person: the view leaving every window, moving to
    /// another or its window no longer shown, and the app resigning after it was active, are triggers.
    @Test func theSurroundingsNameWhatEndedTheRun() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest(); other.closeAfterTest() }
        var now: NSWindow? = window, visible = true, active = true
        let surroundings = DriveSurroundings(windowNow: { now }, window: window, isVisible: { visible }, isActive: { active })
        #expect(surroundings.trigger() == nil)
        active = false
        #expect(surroundings.trigger() == "resign")
        active = true
        visible = false
        #expect(surroundings.trigger() == "window_close")
        visible = true
        now = other
        #expect(surroundings.trigger() == "window_close")
        now = nil
        #expect(surroundings.trigger() == "detached")
        // An app that was not active when the run started has no resign to report.
        let inactive = DriveSurroundings(windowNow: { window }, window: window, isVisible: { true }, isActive: { false })
        #expect(inactive.trigger() == nil)
    }

    /// A trigger that only retries (the view back in a window) never stops a run.
    @Test func aRetryTriggerDuringTheRunDoesNothing() async throws {
        let release = Sends().release()
        release.viewMoved(inWindow: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(release.triggered == nil && !release.released)
        release.viewMoved(inWindow: false)
        #expect(release.triggered == "detached")
    }

    /// A view out of every window fails to release; back in one, the pending release goes in.
    @Test func aDetachedViewIsReleasedWhenItIsBackInAWindow() async throws {
        var inWindow = false
        let release = DriveRelease(send: { inWindow ? .wentIn : .failed }, sleep: { _ in })
        release.armed = true
        await release.release("end")
        release.runEnded = true
        #expect(!release.released)
        inWindow = true
        release.viewMoved(inWindow: true)
        try await settled(release)
        #expect(release.released && release.how == "window")
    }

    /// Every way a run ends leaves the release done: its own paths, the backstop, each trigger, and a
    /// send that fails any number of times under the cap first.
    /// The view comes back to a window while a round is failing: that round runs out, and the re-attach
    /// gets a round of its own, whose send goes in, rather than only the failing round's rest. (A
    /// teardown in a round ends it there: nothing is left to hold.)
    @Test func aReattachDuringAFailingRoundStartsItsOwnRound() async throws {
        let sends = Sends(Array(repeating: .failed, count: 1 + DriveRelease.retryWaits.count))
        let release = sends.release()
        release.runEnded = true
        sends.onWait = { wait in
            if wait == 2 { release.viewMoved(inWindow: true) }
        }
        await release.release("end")
        try await settled(release)
        #expect(release.released, "the release stayed pending after a re-attach during a failing round")
        #expect(release.how == "window")
        #expect(sends.count == 2 + DriveRelease.retryWaits.count, "\(sends.count) sends")
    }

    /// The sends of one whole failed round.
    static let round = DriveRelease.retryWaits.count + 1

    /// The app's later rounds: at most 3, 2 s, 10 s and 30 s after a failed round.
    @Test func theLaterRoundsAreBounded() {
        #expect(DriveRelease.laterRounds == [.seconds(2), .seconds(10), .seconds(30)])
    }

    /// A round that fails is followed by a later one on the schedule; the one that goes in ends the
    /// release, and no round is scheduled after it.
    @Test func laterRoundsFireOnTheScheduleAndStopOnceReleased() async throws {
        let sends = Sends(Array(repeating: .failed, count: 2 * Self.round))
        let release = sends.release(later: [.milliseconds(20), .milliseconds(20), .milliseconds(20)])
        await release.release("end")
        #expect(!release.released)
        #expect(release.laterRoundsLeft == 3 && release.isLaterRoundScheduled)
        try await settled(release)
        #expect(release.released && release.how == "later")
        #expect(sends.count == 2 * Self.round + 1, "the third round's first send goes in")
        #expect(release.laterRoundsLeft == 1)
        #expect(!release.isLaterRoundScheduled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sends.count == 2 * Self.round + 1, "a round ran after the release")
    }

    /// Past every later round the release stays pending with nothing scheduled: only a trigger (the
    /// view back in a window, the tab closing, the person's pointer) ends it.
    @Test func pastTheLaterRoundsNothingMoreIsScheduled() async throws {
        let sends = Sends(Array(repeating: .failed, count: 100))
        let release = sends.release(later: [.milliseconds(10), .milliseconds(10)])
        await release.release("end")
        let deadline = ContinuousClock.now + .seconds(5)
        while release.laterRoundsLeft > 0 || release.isLaterRoundScheduled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!release.released && release.laterRoundsLeft == 0 && !release.isLaterRoundScheduled)
        #expect(sends.count == 3 * Self.round)
        release.runEnded = true
        release.personPointer()
        #expect(release.released && release.how == "person_pointer")
    }

    /// The person's real pointer in the pane: WebKit's hover follows it, so nothing synthetic is left.
    /// AppKit tells the watch from the real cursor only (its tracking area); the run's own events go
    /// straight to the web view and never reach it.
    @Test func aPendingReleaseEndsOnTheRealPointerInThePane() async throws {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let release = Sends(Array(repeating: .failed, count: Self.round)).release()
        await release.release("end")
        release.runEnded = true
        #expect(!release.released)
        let watch = DrivePointerWatch(release: release)
        watch.install(on: pane)
        #expect(pane.trackingAreas.contains { ($0.owner as AnyObject?) === watch })
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        watch.mouseEntered(with: event)
        #expect(release.released && release.how == "person_pointer")
        // Released: the watch is gone from the pane.
        #expect(!pane.trackingAreas.contains { ($0.owner as AnyObject?) === watch })
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A tracking area does not keep its owner: the release registered on its view holds its pointer watch
    /// for as long as it is pending (nothing else does), and every end drops it, its tracking area with it.
    /// Nothing is left holding the release or the view after it: no cycle through the watch.
    @Test(arguments: ["person_pointer", "window", "teardown", "later"])
    func aPendingReleaseHoldsItsPointerWatchUntilItEnds(_ end: String) async throws {
        _ = NSApplication.shared
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        let sends = Sends(Array(repeating: .failed, count: Self.round))
        weak var watch: DrivePointerWatch?
        weak var held: DriveRelease?
        autoreleasepool {
            let release = sends.release(later: end == "later" ? [.milliseconds(20)] : [])
            release.register(on: view)
            watch = release.pointerWatch
            held = release
        }
        #expect(watch != nil, "the pointer watch was freed while its release is pending")
        #expect(view.trackingAreas.contains { ($0.owner as AnyObject?) === watch })
        do {
            let release = try #require(held)
            // A round that fails: the release stays pending, and keeps its watch.
            await release.release("end")
            release.runEnded = true
            #expect(!release.released && watch != nil)
            switch end {
            case "person_pointer":
                // Through the watch's own callback: the release drops the watch while AppKit is calling it.
                let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
                watch?.mouseEntered(with: event)
            case "teardown": view.close()
            case "later": break
            default: release.trigger(end)
            }
            try await settled(release)
            #expect(release.released && release.how == end)
        }
        #expect(watch == nil, "the pointer watch outlived its release")
        #expect(!view.trackingAreas.contains { $0.owner is DrivePointerWatch }, "the watch's tracking area stayed on the pane")
        #expect(view.heldDrives.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while held != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(held == nil, "something still holds the ended release")
    }

    /// During the run the person's pointer in the pane is the person: the run stops and releases.
    @Test func theRealPointerDuringTheRunInterruptsIt() async throws {
        let release = Sends().release()
        release.personPointer()
        #expect(release.triggered == "person")
        try await settled(release)
        #expect(release.released && release.how == "person")
    }

    /// The run's own move and release go to the web view, never through the pane's tracking area.
    @Test func theRunsOwnMovesNeverReachTheWatch() async throws {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let webView = WKWebView(frame: pane.bounds, configuration: WKWebViewConfiguration())
        pane.addSubview(webView)
        let window = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = pane
        let release = Sends().release()
        release.runEnded = true
        let watch = DrivePointerWatch(release: release)
        watch.install(on: pane)
        let input = AgentChatDriveInput(webView: webView)
        #expect(await input.move(to: CGPoint(x: 50, y: 50)))
        #expect(await input.release() == .wentIn)
        #expect(!release.released, "a synthetic move counted as the person's pointer")
        watch.remove()
    }

    @Test func everyWayARunEndsReleases() async throws {
        for path in ["end", "error", "cancel", "person"] {
            for fails in 0...DriveRelease.retryWaits.count {
                let release = Sends(Array(repeating: .failed, count: fails)).release()
                await release.release(path)
                #expect(release.released && release.how == path, "\(path) after \(fails) failed sends")
            }
        }
        for trigger in ["teardown", "window_close", "resign", "detached"] {
            let release = Sends([.failed, .failed]).release()
            release.trigger(trigger)
            try await settled(release)
            #expect(release.released && release.how == trigger, "\(trigger)")
            #expect(release.triggered == trigger)
        }
        let timed = Sends([.failed]).release()
        timed.armBackstop(after: .milliseconds(20))
        try await settled(timed)
        #expect(timed.released && timed.how == "timer")
        // A teardown during a failing round ends it as released: nothing is left to hold.
        let closing = Sends(Array(repeating: .failed, count: 50)).release()
        closing.trigger("teardown")
        try await settled(closing)
        #expect(closing.released && closing.how == "teardown")
        // A path whose round keeps failing is completed by a later round, or by the person's pointer.
        for path in ["end", "error", "cancel", "person", "timer"] {
            let later = Sends(Array(repeating: .failed, count: Self.round)).release(later: [.milliseconds(10)])
            await later.release(path)
            try await settled(later)
            #expect(later.released && later.how == "later", "\(path), then a later round")
            let pointer = Sends(Array(repeating: .failed, count: 100)).release()
            await pointer.release(path)
            pointer.runEnded = true
            pointer.personPointer()
            #expect(pointer.released && pointer.how == "person_pointer", "\(path), then the person's pointer")
        }
    }

    /// The person's pointer comes into the pane while the run is still starting (its engine counters), before
    /// any hover exists. The release is armed from the start, so it is not "done" with nothing held, and the
    /// run makes no hover after it: a hover made then would have no release left to end it.
    @Test func thePersonsPointerDuringStartupLeavesNoHoverBehind() async throws {
        let sends = Sends()
        let release = sends.release(armed: true)
        #expect(release.mayHover)
        release.personPointer()
        #expect(!release.mayHover, "the run would hover after the person's pointer started the release")
        try await settled(release)
        #expect(release.released && release.triggered == "person")
        #expect(sends.count == 1, "an armed release sends its pointer-leave rather than counting nothing as released")
    }

    /// The backstop fires while the run is still starting (a slow `startEngineCounters`): a release has
    /// started, so the run makes no hover whether that round went in or failed, and it names the timer,
    /// not the person.
    @Test(arguments: [true, false])
    func aBackstopDuringStartupLeavesNoHoverAndNamesTheTimer(wentIn: Bool) async throws {
        let sends = Sends(wentIn ? [] : Array(repeating: .failed, count: Self.round))
        let release = sends.release(armed: true)
        #expect(release.mayHover && release.interruption == nil)
        release.armBackstop(after: .milliseconds(10))
        let deadline = ContinuousClock.now + .seconds(5)
        while sends.count < (wentIn ? 1 : Self.round), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(release.released == wentIn)
        #expect(!release.mayHover, "the run would hover after the backstop started the release")
        #expect(release.interruption == "timer", "the run would say the person interrupted it")
        #expect(release.triggered == nil, "the timer is no trigger from outside the run")
    }
}
