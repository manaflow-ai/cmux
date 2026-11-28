import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// The palette's first open is a sign that a row may open the icon picker or the group editor next (their Set Icon and
/// Rename rows), so the app makes those WebKit pages then instead of at launch (Leo 2026-11-14, Home idle memory).
/// The work runs once, after the open (never inside it, so the panel's first frame is not held up).
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteFirstShowTests {
    @Test(.timeLimit(.minutes(1))) func theFirstOpenRunsTheWorkOnceAfterItAndNothingBefore() async {
        _ = NSApplication.shared
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        var ran = 0
        palette.onFirstShow { ran += 1 }
        _ = palette.prepare(step: 0)
        await Self.nextCommittedPass()
        #expect(ran == 0, "the launch warm-up of the palette ran the work")

        palette.show(.commands)
        #expect(ran == 0, "the work ran inside the open, before its frame was committed")
        await Self.nextCommittedPass()
        #expect(ran == 1, "the first open did not run the work")

        palette.hide()
        palette.show(.commands)
        await Self.nextCommittedPass()
        #expect(ran == 1, "a later open ran the work again")
    }

    /// Waits until the main run loop's next pass reaches its before-waiting stage, where the open's after-frame-commit
    /// work runs (a one-shot observer ordered after it). Not a 0 s `CFRunLoopRunInMode`: a 0 s run only polls, and a
    /// polling pass skips the before-waiting stage, so the work never ran in this test (fleet step 6e96862e).
    private static func nextCommittedPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                done.resume()
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }
}
