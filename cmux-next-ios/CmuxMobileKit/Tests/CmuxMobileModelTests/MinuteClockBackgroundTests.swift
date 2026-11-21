import Foundation
import Testing
@testable import CmuxMobileModel

/// The shared minute clock (and the Feed rows that redraw on it) does not wake
/// the phone each minute while the app is in the background; in front again it
/// reads the time at once, so every relative time is current on return.
@MainActor
@Suite struct MinuteClockBackgroundTests {
    @Test func backgroundPausesTheTicksAndForegroundCatchesUpAtOnce() {
        let launched = Date(timeIntervalSinceNow: -3600)
        let clock = MinuteClock(now: launched)
        #expect(clock.isTicking)
        clock.setActive(false)
        #expect(!clock.isTicking)
        clock.setActive(true)
        #expect(clock.isTicking)
        #expect(clock.now.timeIntervalSince(launched) > 3500)
        clock.setActive(false)
    }

    @Test func aHeldClockStaysHeld() {
        let held = Date(timeIntervalSince1970: 1_000)
        let clock = MinuteClock(now: held, ticking: false)
        clock.setActive(true)
        #expect(!clock.isTicking)
        #expect(clock.now == held)
    }
}
