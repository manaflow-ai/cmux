import CmuxNextMemory
import Foundation
import Testing

/// The app's ``MainRunLoopReleaseTurns`` runs each turn once, on a later default-mode pass of the main
/// run loop: never inline, and never inside a menu's or a drag's tracking mode.
@MainActor @Suite struct MainRunLoopReleaseTurnsTests {
    private final class Runs {
        var count = 0
    }

    /// One pass of the main run loop in `mode` (a no-op block keeps it from waiting).
    private func runMainRunLoopPass(_ mode: CFRunLoopMode = .defaultMode) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), mode.rawValue) {}
        _ = CFRunLoopRunInMode(mode, 0, false)
    }

    @Test func aTurnRunsOnceOnALaterDefaultModePass() {
        let runs = Runs()
        MainRunLoopReleaseTurns().scheduleTurn { runs.count += 1 }
        #expect(runs.count == 0, "the turn ran before scheduleTurn returned")
        runMainRunLoopPass()
        #expect(runs.count == 1)
        runMainRunLoopPass()
        #expect(runs.count == 1, "one scheduleTurn ran the turn twice")
    }

    @Test func aTrackingModePassRunsNoTurn() {
        let tracking = CFRunLoopMode(rawValue: "MainRunLoopReleaseTurnsTests.tracking" as CFString)
        let main = CFRunLoopGetMain()
        let keep: CFRunLoopObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.exit.rawValue, true, 0) { _, _ in }
        CFRunLoopAddObserver(main, keep, tracking)
        CFRunLoopAddCommonMode(main, tracking)
        defer { CFRunLoopObserverInvalidate(keep) }
        let runs = Runs()
        MainRunLoopReleaseTurns().scheduleTurn { runs.count += 1 }
        runMainRunLoopPass(tracking)
        #expect(runs.count == 0, "a release turn ran inside a tracking loop")
        runMainRunLoopPass()
        #expect(runs.count == 1)
    }
}
