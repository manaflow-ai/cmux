import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import QuartzCore
import Testing

/// An open is timed at the frame that first shows it (`onPresented`, `debug.timings` palette_opens, the bench row
/// palette.*_cmd_shift_p.key_to_frame), not when the animations of the open's turn end. The timer was the
/// completion of the turn's implicit Core Animation transaction, which waits for every animation added after it in
/// that turn (such as the search field's loading spinner while a page provider loads). The release run 5a98b61fd6bc
/// reported every Cmd-Shift-P open at 528.9 to 536.9 ms against Cmd-P's 19 ms, and 6 of its 12 rows failed for
/// opens that reported no timing before the bench read them.
@MainActor
@Suite(.paletteRanker, .serialized, .closesItsWindows)
struct PaletteOpenTimedAtFirstFrameTests {
    @Test func anAnimationAddedInTheOpensTurnDoesNotHoldItsTiming() throws {
        _ = NSApplication.shared
        let palette = PaletteController(registry: .standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.bindRegistryActions()
        palette.prepare(step: 0)
        palette.prepare(step: 1)
        var timings: [PaletteOpenTiming] = []
        palette.onPresented = { timings.append($0) }

        #expect(palette.registry.perform("commandPalette"))
        #expect(palette.isVisible)
        // Something in the open's turn starts an animation that runs on (the search field's spinner while a provider
        // loads): an hour-long one, so only a timer that waits for it can miss the frame.
        let layer = try #require(palette.visiblePanel?.contentView?.layer)
        let spinner = CABasicAnimation(keyPath: "opacity")  // motion: allow a test stand-in for the spinner's turn
        spinner.fromValue = 1
        spinner.toValue = 1
        spinner.duration = 3600
        layer.add(spinner, forKey: "test.spinner")
        defer { layer.removeAnimation(forKey: "test.spinner") }
        // Run the main run loop until the open is timed, for at most 2 s: a pass that handles a source or main-queue
        // work first returns before its before-waiting point, so the number of passes is not fixed. The animation
        // runs an hour, so a timer that waits for it reports nothing in this window.
        let deadline = ContinuousClock.now + .seconds(2)
        while timings.isEmpty, ContinuousClock.now < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        #expect(timings.count == 1, "the open was not timed at its first frame: \(timings.count) timing(s) within 2 s")
    }
}
