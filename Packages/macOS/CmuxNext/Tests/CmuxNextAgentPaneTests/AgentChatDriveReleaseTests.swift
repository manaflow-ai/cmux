import AppKit
@testable import CmuxNextAgentPane
import CmuxNextTestSupport
import Foundation
import Testing

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

        init(_ answers: [Outcome] = []) {
            self.answers = answers
        }

        func release(armed: Bool = true) -> DriveRelease {
            let release = DriveRelease(send: { [self] in
                count += 1
                return answers.isEmpty ? .wentIn : answers.removeFirst()
            }, sleep: { [self] in waits.append($0) })
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
    }
}
