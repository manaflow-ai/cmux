@testable import CmuxNextAgentPane
import Foundation
import Testing

/// `agent.chat.drive` hands the pointer back to the person: its hold watches for them every
/// ``DriveWatch/step`` (type-only runs too, which are all hold), and its release counts only once
/// the pointer-leave went in. A failed release leaves the backstop armed for a later path or the timer.
@MainActor
@Suite(.timeLimit(.minutes(1)))
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

    @Test func nothingHeldIsReleasedWithoutAnEvent() async {
        var sent = 0
        let release = DriveRelease { sent += 1; return true }
        await release.release("end")
        #expect(release.released && release.how == "end")
        #expect(sent == 0)
    }

    @Test func aFailedReleaseIsNotAReleaseAndKeepsTheBackstop() async {
        var answers = [false, true]
        let release = DriveRelease { answers.removeFirst() }
        release.armed = true
        release.armBackstop(after: .seconds(60))
        await release.release("error")
        #expect(!release.released)
        #expect(release.how == nil)
        #expect(release.isBackstopArmed)
        await release.release("end")
        #expect(release.released && release.how == "end")
        #expect(!release.isBackstopArmed)
        // Once released, no path sends again.
        await release.release("timer")
        #expect(release.how == "end")
        #expect(answers.isEmpty)
    }

    @Test func theBackstopReleasesWhenTheRunNeverDoes() async throws {
        var sent = 0
        let release = DriveRelease { sent += 1; return true }
        release.armed = true
        release.armBackstop(after: .milliseconds(50))
        let deadline = ContinuousClock.now + .seconds(5)
        while !release.released, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(release.released && release.how == "timer")
        #expect(sent == 1)
    }
}
