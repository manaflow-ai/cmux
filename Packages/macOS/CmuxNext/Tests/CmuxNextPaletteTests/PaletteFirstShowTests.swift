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
    @Test func theFirstOpenRunsTheWorkOnceAfterItAndNothingBefore() {
        _ = NSApplication.shared
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        var ran = 0
        palette.onFirstShow { ran += 1 }
        _ = palette.prepare(step: 0)
        Self.runMainRunLoopPass()
        #expect(ran == 0, "the launch warm-up of the palette ran the work")

        palette.show(.commands)
        #expect(ran == 0, "the work ran inside the open, before its frame was committed")
        Self.runMainRunLoopPass()
        #expect(ran == 1, "the first open did not run the work")

        palette.hide()
        palette.show(.commands)
        Self.runMainRunLoopPass()
        #expect(ran == 1, "a later open ran the work again")
    }

    /// One pass of the main run loop: the open's after-frame-commit work runs at its before-waiting point.
    private static func runMainRunLoopPass() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }
}
