@testable import CmuxNextControl
import CoreFoundation
import Foundation
import CmuxNextCompat
import Testing

/// ``MainThreadWatchdog/stop()`` runs on any thread, so it does not touch the main run loop's observers: each one
/// removes itself, on the main thread, at its first call after the stop (or once the watchdog is gone). After
/// that call no heartbeat counts, and no observer is left to fire on every later turn.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogObserverLifetimeTests {
    #if DEBUG
    @MainActor
    @Test func aStoppedWatchdogCountsNoBeatAndItsObserversLeaveAtTheirNextCall() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        watchdog.start()
        let observers = watchdog.observersForTesting
        #expect(observers.live.load(ordering: .relaxed) == 2)
        Self.runOneMainTurn()
        #expect(watchdog.currentBeat != 0, "the observers beat while the watchdog runs")
        #expect(observers.live.load(ordering: .relaxed) == 2)

        watchdog.stop()
        let beat = watchdog.currentBeat
        let gaps = watchdog.gapStats, frames = watchdog.longFrameStats, stalls = watchdog.stallCounts
        let wakes = watchdog.mainRunLoopWakes
        // The last beat left the main thread awake: one more would count a 300 ms gap, a long frame and a stall.
        clock.advance(by: .milliseconds(300))
        Self.runTurnsUntilNoObserver(observers)
        #expect(observers.live.load(ordering: .relaxed) == 0, "both observers left the main run loop")
        #expect(watchdog.currentBeat == beat)
        #expect(watchdog.gapStats.over120HzFrame == gaps.over120HzFrame)
        #expect(watchdog.gapStats.max == gaps.max)
        #expect(watchdog.longFrameStats.count == frames.count)
        #expect(watchdog.longFrameStats.max == frames.max)
        #expect(watchdog.stallCounts.count100 == stalls.count100)
        #expect(watchdog.stallCounts.count250 == stalls.count250)
        #expect(watchdog.mainRunLoopWakes == wakes)
        #expect(watchdog.log.summary.count == 0)

        // A later turn finds nothing of the watchdog on the run loop.
        clock.advance(by: .milliseconds(300))
        Self.runOneMainTurn()
        #expect(watchdog.currentBeat == beat)
        #expect(observers.live.load(ordering: .relaxed) == 0)
    }

    /// The observers hold the watchdog weakly: once its thread ended and the last reference is gone, nothing keeps
    /// it alive, and the observers still leave the main run loop at their next call.
    @MainActor
    @Test func aReleasedWatchdogLeavesNoObserverOnTheMainRunLoop() {
        weak var released: MainThreadWatchdog?
        let observers: MainThreadWatchdog.ObserverCountForTesting
        do {
            let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false),
                                              uptime: ManualUptime().read)
            watchdog.start()
            observers = watchdog.observersForTesting
            released = watchdog
            Self.runOneMainTurn()
            #expect(watchdog.currentBeat != 0)
            // stop() ends the watchdog thread, which holds the watchdog until it returns.
            watchdog.stop()
        }
        Self.runTurnsUntilNoObserver(observers)
        #expect(observers.live.load(ordering: .relaxed) == 0, "both observers left the main run loop")
        // The watchdog thread ends on its own after stop()'s wake; nothing else holds the watchdog.
        spinMainRunLoop(until: { released == nil })
        #expect(released == nil, "a stopped watchdog is freed")
    }

    /// One main run-loop turn that sleeps and wakes: a timer already due ends it, so the early observer sees the
    /// entry, the late one the before-waiting, and nothing waits on time.
    @MainActor
    private static func runOneMainTurn() {
        let end = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0, 0, 0) { _ in
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), end, .defaultMode)
        defer { CFRunLoopTimerInvalidate(end) }
        CFRunLoopRunInMode(.defaultMode, 30, false)
    }

    /// A turn whose wait another source cut short skips the before-waiting call: a few turns at most.
    @MainActor
    private static func runTurnsUntilNoObserver(_ observers: MainThreadWatchdog.ObserverCountForTesting) {
        for _ in 0..<5 where observers.live.load(ordering: .relaxed) > 0 {
            runOneMainTurn()
        }
    }
    #endif
}
