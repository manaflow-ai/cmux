import CmuxNextCompat
import Foundation
import QuartzCore
import Testing

/// Runs one pass of the main run loop in `mode` without waiting (a 0 s timeout).
///
/// The empty block keeps the mode from being empty: `CFRunLoopRunInMode` returns from an empty
/// mode before its observers run. Inside a main-queue job the run loop does not count the main
/// queue as a source, so a test pass sees only what the test queued.
private func runMainRunLoopPass(_ mode: CFRunLoopMode = .defaultMode) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), mode.rawValue) {}
    _ = CFRunLoopRunInMode(mode, 0, false)
}

/// A mode the main run loop treats as a common mode, as AppKit's event-tracking mode (menus,
/// drags) once AppKit adds it. A no-op observer makes the run loop create the mode.
private func commonTrackingMode() -> (mode: CFRunLoopMode, keep: CFRunLoopObserver) {
    let mode = CFRunLoopMode(rawValue: "MainCallbackSeamTests.tracking" as CFString)
    let main = CFRunLoopGetMain()
    let keep: CFRunLoopObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.exit.rawValue, true, 0) { _, _ in }
    CFRunLoopAddObserver(main, keep, mode)
    CFRunLoopAddCommonMode(main, mode)
    return (mode, keep)
}

/// What the callbacks under test saw, in order.
private final class CallbackLog {
    var events: [String] = []

    func record(_ event: String) {
        events.append(Thread.isMainThread ? event : event + " off main")
    }
}

@Suite struct MainRunLoopBlockTests {
    @Test func runsOnMainOnALaterPassOnce() {
        let log = CallbackLog()
        MainRunLoopBlock.perform { log.record("block") }
        #expect(log.events.isEmpty, "the block ran inline, before the caller returned")
        runMainRunLoopPass()
        #expect(log.events == ["block"])
        runMainRunLoopPass()
        #expect(log.events == ["block"], "one perform ran the block more than once")
    }

    /// In the default `.commonModes` the block also runs while a menu or drag tracks events;
    /// a block given one mode waits for that mode.
    @Test func runsInEveryCommonModeOrOnlyInTheModeGiven() {
        let tracking = commonTrackingMode()
        defer { CFRunLoopObserverInvalidate(tracking.keep) }
        let log = CallbackLog()
        MainRunLoopBlock.perform { log.record("common") }
        MainRunLoopBlock.perform(mode: .defaultMode) { log.record("default") }
        runMainRunLoopPass(tracking.mode)
        #expect(log.events == ["common"])
        runMainRunLoopPass()
        #expect(log.events == ["common", "default"])
    }

    @Test func aKeptBlockRunsOncePerPerform() {
        let log = CallbackLog()
        let block = MainRunLoopBlock { log.record("kept") }
        block.perform()
        block.perform()
        runMainRunLoopPass()
        #expect(log.events == ["kept", "kept"])
    }

    @Test func aBlockQueuedOffTheMainThreadRunsOnMain() async {
        let log = CallbackLog()
        await Task.detached { MainRunLoopBlock.perform { log.record("from a background thread") } }.value
        runMainRunLoopPass()
        #expect(log.events == ["from a background thread"])
    }
}

@Suite struct MainRunLoopObserverTests {
    @Test func callsTheHandlerOnMainUntilReleased() {
        let log = CallbackLog()
        var observer: MainRunLoopObserver? = MainRunLoopObserver(activities: .beforeSources) { activity in
            log.record(activity == .beforeSources ? "beforeSources" : "activity \(activity.rawValue)")
        }
        runMainRunLoopPass()
        let seen = log.events.count
        #expect(seen > 0)
        #expect(log.events.allSatisfy { $0 == "beforeSources" }, "\(log.events)")
        #expect(observer?.isValid == true)
        observer = nil
        runMainRunLoopPass()
        #expect(log.events.count == seen, "the observer ran after its token was released")
    }

    @Test func invalidateStopsTheHandler() {
        let log = CallbackLog()
        let observer = MainRunLoopObserver(activities: .beforeTimers) { _ in log.record("beforeTimers") }
        observer.invalidate()
        #expect(!observer.isValid)
        runMainRunLoopPass()
        #expect(log.events.isEmpty)
    }

    @Test func aNonRepeatingObserverRunsOnce() {
        let log = CallbackLog()
        let observer = MainRunLoopObserver(activities: .beforeSources, repeats: false) { _ in log.record("once") }
        runMainRunLoopPass()
        runMainRunLoopPass()
        #expect(log.events == ["once"])
        #expect(!observer.isValid)
    }

    /// The one-shot form keeps no token: the run loop holds the observer until its one call.
    @Test func onceRunsOnMainOnALaterPassWithoutAToken() {
        let log = CallbackLog()
        MainRunLoopObserver.once(activities: .beforeSources) { log.record("once") }
        #expect(log.events.isEmpty, "the work ran inline, before the caller returned")
        runMainRunLoopPass()
        runMainRunLoopPass()
        #expect(log.events == ["once"])
    }

    @Test func observesTheCommonModes() {
        let tracking = commonTrackingMode()
        defer { CFRunLoopObserverInvalidate(tracking.keep) }
        let log = CallbackLog()
        let observer = MainRunLoopObserver(activities: .beforeSources, repeats: false) { _ in log.record("tracking") }
        runMainRunLoopPass(tracking.mode)
        #expect(log.events == ["tracking"])
        withExtendedLifetime(observer) {}
    }
}

@Suite struct CATransactionMainCompletionTests {
    /// With no animation the completion runs once the transaction commits (CATransaction.h),
    /// on the main thread.
    @Test(.timeLimit(.minutes(1))) func theCompletionRunsOnMainAfterTheCommit() async {
        let log = CallbackLog()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setMainCompletion {
                log.record("completion")
                done.resume()
            }
            log.record("commit")
            CATransaction.commit()
        }
        #expect(log.events == ["commit", "completion"])
    }
}
