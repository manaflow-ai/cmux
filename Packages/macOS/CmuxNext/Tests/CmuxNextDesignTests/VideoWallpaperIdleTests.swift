import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Every video wallpaper (a file or a YouTube video) plays on the Rust scheduler's answer
/// (``BackdropPlayback``), and pauses after `appearance.videoWallpaperIdlePause` seconds without
/// input; ``BackdropIdle`` only wakes it when that answer can change.
@MainActor @Suite(.serialized) struct VideoWallpaperIdleTests {
    /// The decision table: seen x Low Power x hot x Reduce Motion x idle x frontmost (x covered,
    /// x exclusive), asked of Rust through the C ABI.
    @Test func aVideoPlaysOnlyWhenEveryTermAllowsIt() {
        let flags = [false, true]
        var rows = 0
        for seen in flags {
            for covered in flags {
                for lowPower in flags {
                    for hot in flags {
                        for reduceMotion in flags {
                            for idle in flags {
                                for exclusive in flags {
                                    for frontmost in flags {
                                        var terms = BackdropPlayback.Terms()
                                        terms.visible = seen
                                        terms.covered = covered
                                        terms.lowPower = lowPower
                                        terms.hot = hot
                                        terms.reduceMotion = reduceMotion
                                        terms.idleAfter = 300
                                        terms.secondsSinceInput = idle ? 300 : 299
                                        terms.exclusive = exclusive
                                        terms.chosen = frontmost
                                        terms.size = CGSize(width: 800, height: 500)
                                        let answer = BackdropPlayback(terms)
                                        let plays = seen && !covered && !lowPower && !hot && !reduceMotion && !idle
                                            && (!exclusive || frontmost)
                                        #expect(answer.plays == plays, "\(terms)")
                                        // Held for power, heat, motion, idle or another window: still seen, the decoder kept.
                                        #expect(answer.canBeSeen == (seen && !covered), "\(terms)")
                                        #expect(answer.idle == (seen && !covered && !lowPower && !hot && !reduceMotion
                                                                && (!exclusive || frontmost) && idle), "\(terms)")
                                        rows += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(rows == 256)
    }

    @Test func zeroNeverPausesAndASmallPlayerHolds() {
        var terms = BackdropPlayback.Terms()
        terms.secondsSinceInput = 1e9
        terms.idleAfter = .infinity
        #expect(BackdropPlayback(terms).plays, "the setting's 0 paused a video")
        terms.exclusive = true
        terms.size = CGSize(width: 199, height: 600)
        #expect(BackdropPlayback(terms).holdReason == BackdropPlayback.holdTooSmall)
        terms.size = CGSize(width: 200, height: 200)
        #expect(BackdropPlayback(terms).plays)
        terms.chosen = false
        #expect(BackdropPlayback(terms).holdReason == BackdropPlayback.holdElsewhere)
    }

    final class Owner {}

    /// Waits for `condition` while a deadline's task runs.
    func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(4))
        }
        return condition()
    }

    @Test(.timeLimit(.minutes(1))) func aPlayingVideoIsWokenAtTheIdleTimeAndAnIdleOneByTheNextCheck() async throws {
        let clock = ManualClock()
        var since: TimeInterval = 100
        var asks = 0
        let idle = BackdropIdle(clock: clock, sinceInput: { since }, settings: nil, pauseAfter: { 300 }, monitorsInput: false)
        #expect(idle.idleAfter == 300 && idle.secondsSinceInput == 100)
        let owner = Owner()
        idle.watch(owner, idle: false) { asks += 1 }
        // One deadline, for the 200 s still missing (and a hair past it).
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines.map(\.offset) == [.milliseconds(200_050)])
        since = 300.05
        clock.advance(by: .milliseconds(200_050))
        #expect(try await eventually { asks == 1 })
        // The owner's answer is now idle: it waits for input, read again every idleCheck.
        idle.watch(owner, idle: true) { asks += 1 }
        try await clock.waitForSleeper()
        #expect(try await eventually { clock.sleeperDeadlines.map(\.offset) == [.milliseconds(200_050) + BackdropIdle.idleCheck] })
        clock.advance(by: BackdropIdle.idleCheck)
        #expect(try await eventually { asks == 2 })
        idle.unwatch(owner)
        #expect(!idle.isWatching(owner))
    }

    @Test func zeroOrNoWatcherRunsNothing() async throws {
        let clock = ManualClock()
        let never = BackdropIdle(clock: clock, sinceInput: { 10 }, settings: nil, pauseAfter: { 0 }, monitorsInput: false)
        #expect(never.idleAfter == .infinity)
        let owner = Owner()
        never.watch(owner, idle: false) {}
        #expect(clock.sleeperCount == 0, "0 left a deadline running")
        never.unwatch(owner)
        _ = BackdropIdle(clock: clock, sinceInput: { 10 }, settings: nil, pauseAfter: { 300 }, monitorsInput: false)
        #expect(clock.sleeperCount == 0, "an idle wake with no video armed itself")
    }
}
