import CmuxMobileDesign
import CoreGraphics
import Testing

/// The shared toast gesture (`ToastDismissal`) and the workspace toast's place (`ToastPlacement`).
@Suite struct ToastRulesTests {
    let top = ToastDismissal(entry: .top)
    let bottom = ToastDismissal(entry: .bottom)

    @Test func aTopToastLeavesUpOrSideways() {
        #expect(top.dismisses(translation: CGSize(width: 0, height: -50), predictedEnd: CGSize(width: 0, height: -60)))
        #expect(top.dismisses(translation: CGSize(width: 70, height: 4), predictedEnd: CGSize(width: 90, height: 4)))
        #expect(top.dismisses(translation: CGSize(width: -70, height: 0), predictedEnd: CGSize(width: -80, height: 0)))
        // Pulled down: it rubber-bands and stays.
        #expect(!top.dismisses(translation: CGSize(width: 0, height: 120), predictedEnd: CGSize(width: 0, height: 200)))
        #expect(top.offset(for: CGSize(width: 0, height: 100)).height == 20)
        #expect(top.offset(for: CGSize(width: 0, height: -30)).height == -30)
    }

    @Test func aFlickDismissesBeforeTheDistance() {
        #expect(top.dismisses(translation: CGSize(width: 0, height: -12), predictedEnd: CGSize(width: 0, height: -130)))
        #expect(!top.dismisses(translation: CGSize(width: 0, height: -12), predictedEnd: CGSize(width: 0, height: -40)))
    }

    @Test func aBottomToastLeavesDownOrSideways() {
        #expect(bottom.dismisses(translation: CGSize(width: 0, height: 50), predictedEnd: CGSize(width: 0, height: 60)))
        #expect(!bottom.dismisses(translation: CGSize(width: 0, height: -80), predictedEnd: CGSize(width: 0, height: -150)))
        #expect(bottom.exitOffset(for: CGSize(width: 0, height: 50), size: CGSize(width: 300, height: 44)).height > 44)
        #expect(top.exitOffset(for: CGSize(width: 80, height: -5), size: CGSize(width: 300, height: 44)).width > 300)
    }

    // iPhone 17 Pro, 402 x 874 pt: safe areas 62 (top) and 34 (bottom).
    let screen = (height: CGFloat(874), top: CGFloat(62), bottom: CGFloat(34))

    @Test func onAPageTheToastIsAtTheTopClearOfEveryControl() {
        let page = ToastPlacement(screen: .page)
        #expect(page.entry == .top)
        // The page's controls (AX frames): title pill and Back y 792, chat composer y 726,
        // terminal composer y 465 and key bar y 526 with the keyboard up, keyboard from y 585.
        let controls = [CGRect(x: 90, y: 792, width: 222, height: 48), CGRect(x: 34, y: 792, width: 48, height: 48),
                        CGRect(x: 24, y: 726, width: 354, height: 44), CGRect(x: 14, y: 465, width: 374, height: 44),
                        CGRect(x: 10, y: 526, width: 382, height: 34), CGRect(x: 0, y: 585, width: 402, height: 289)]
        // Up to an AX5 toast (about 140 pt).
        for height in [CGFloat(40), 140] {
            for control in controls {
                #expect(page.clears(control, toastHeight: height, screenHeight: screen.height, safeTop: screen.top, safeBottom: screen.bottom))
            }
        }
    }

    @Test func inTheGridTheToastSitsAboveTheBottomControlsClearOfTheHeaderAndCards() {
        let grid = ToastPlacement(screen: .grid)
        #expect(grid.entry == .bottom)
        // Grid header y 62–106; the first row of cards (with their close buttons) y 122;
        // the bottom controls (New Tab, tab count, Done) y 788–836.
        let header = CGRect(x: 20, y: 62, width: 362, height: 44)
        let closeButtons = CGRect(x: 160, y: 122, width: 230, height: 30)
        let controls = CGRect(x: 38, y: 788, width: 326, height: 48)
        for height in [CGFloat(40), 140] {
            for control in [header, closeButtons, controls] {
                #expect(grid.clears(control, toastHeight: height, screenHeight: screen.height, safeTop: screen.top, safeBottom: screen.bottom))
            }
        }
        let frame = grid.frame(toastHeight: 40, screenHeight: screen.height, safeTop: screen.top, safeBottom: screen.bottom)
        #expect(abs(frame.maxY - (874 - 34 - 64)) < 0.01)
    }

    /// A toast stays long enough to read: 4 s for a short line, longer for steps, never past 12 s.
    @Test func aLongToastStaysLongEnoughToRead() {
        #expect(ToastDismissal.lifetime(for: "Connect to cmux's Mac mini first.") == .seconds(4))
        let steps = "Claude Code hasn't been trusted in proj yet. Either: 1. On the Mac, open this workspace in cmux and choose Trust when it asks. "
            + "Or 2. Here, open this workspace's terminal, type claude, press Return, choose \u{201C}Yes, I trust this folder\u{201D}, then type /exit. "
            + "Then start the chat again."
        #expect(ToastDismissal.lifetime(for: steps) > .seconds(12) - .milliseconds(1))
        #expect(ToastDismissal.lifetime(for: String(repeating: "word ", count: 24)) == .seconds(8))
    }
}
