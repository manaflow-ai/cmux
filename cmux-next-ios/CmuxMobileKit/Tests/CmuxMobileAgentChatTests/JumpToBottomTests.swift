import CmuxMobileDesign
import CoreGraphics
import Testing

/// The jump-to-bottom rule (verify/jump-button.md). Offsets are a scroll
/// view's `contentOffset.y`; `minOffsetY` is `-contentInset.top`,
/// `maxOffsetY` the offset that shows the newest turn on the composer.
@Suite struct JumpToBottomVisibilityTests {
    typealias V = JumpToBottomVisibility

    /// The user's recording: an empty (or short) chat pulled down. The
    /// rubber band moved the offset 100+ pt above the top, which read as
    /// "100 pt from the bottom".
    @Test func emptyChatPulledDownStaysHidden() {
        // Empty transcript: top and bottom offsets coincide.
        for pull in stride(from: 0 as CGFloat, through: 400, by: 10) {
            #expect(!V.next(isShown: false, offsetY: -200 - pull, minOffsetY: -200, maxOffsetY: -200))
        }
    }

    @Test func shortChatPulledDownStaysHidden() {
        // Content 60 pt taller than the space: never 120 pt from the bottom.
        for pull in stride(from: 0 as CGFloat, through: 400, by: 10) {
            #expect(!V.next(isShown: false, offsetY: -62 - pull, minOffsetY: -62, maxOffsetY: -2))
        }
    }

    @Test func bottomOverscrollStaysHidden() {
        #expect(!V.next(isShown: false, offsetY: 1300, minOffsetY: -62, maxOffsetY: 1000))
    }

    @Test func showsOnlyPastTheShowDistance() {
        let max: CGFloat = 2000
        #expect(!V.next(isShown: false, offsetY: max - 40, minOffsetY: -62, maxOffsetY: max))
        #expect(!V.next(isShown: false, offsetY: max - 100, minOffsetY: -62, maxOffsetY: max))
        #expect(V.next(isShown: false, offsetY: max - V.showDistance - 1, minOffsetY: -62, maxOffsetY: max))
    }

    @Test func hysteresisKeepsItSteadyNearTheThreshold() {
        let max: CGFloat = 2000
        // Shown: stays until the reader is back within the hide distance.
        #expect(V.next(isShown: true, offsetY: max - 100, minOffsetY: -62, maxOffsetY: max))
        #expect(V.next(isShown: true, offsetY: max - V.hideDistance - 1, minOffsetY: -62, maxOffsetY: max))
        #expect(!V.next(isShown: true, offsetY: max - V.hideDistance + 1, minOffsetY: -62, maxOffsetY: max))
        // Jitter around 100 pt never flips a hidden button on.
        var shown = false
        for d: CGFloat in [95, 105, 98, 110, 100, 104] {
            shown = V.next(isShown: shown, offsetY: max - d, minOffsetY: -62, maxOffsetY: max)
            #expect(!shown)
        }
        #expect(V.hideDistance < V.showDistance)
    }

    @Test func longChatAtTheTopPulledDownStaysShown() {
        // A reader at the top of a long transcript is far from the bottom,
        // with or without the rubber band.
        #expect(V.next(isShown: true, offsetY: -162, minOffsetY: -62, maxOffsetY: 2000))
        #expect(V.next(isShown: false, offsetY: -162, minOffsetY: -62, maxOffsetY: 2000))
    }

    @Test func keyboardDragDismissNeverShowsIt() {
        let max: CGFloat = 2000
        #expect(!V.next(isShown: false, offsetY: max - 300, minOffsetY: -62, maxOffsetY: max, keyboardDragging: true))
        // Already shown (the reader was scrolled up): it stays, and still hides near the bottom.
        #expect(V.next(isShown: true, offsetY: max - 300, minOffsetY: -62, maxOffsetY: max, keyboardDragging: true))
        #expect(!V.next(isShown: true, offsetY: max - 10, minOffsetY: -62, maxOffsetY: max, keyboardDragging: true))
    }
}

@Suite struct JumpToBottomVisibilityStateTests {
    @Test func updateCarriesTheStateAcrossFrames() {
        var jump = JumpToBottomVisibility()
        // A real scroll up, back down to 100 pt (still shown), then home.
        let up = jump.update(offsetY: 1700, minOffsetY: -62, maxOffsetY: 2000)
        let near = jump.update(offsetY: 1900, minOffsetY: -62, maxOffsetY: 2000)
        let home = jump.update(offsetY: 1990, minOffsetY: -62, maxOffsetY: 2000)
        #expect(up && near && !home)
        // A pull on an empty chat after that: hidden every frame.
        for pull in stride(from: 0 as CGFloat, through: 300, by: 5) {
            let shown = jump.update(offsetY: -300 - pull, minOffsetY: -300, maxOffsetY: -300)
            #expect(!shown)
        }
    }
}
