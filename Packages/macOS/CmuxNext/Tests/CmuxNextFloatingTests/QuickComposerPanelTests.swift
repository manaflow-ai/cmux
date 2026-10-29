import AppKit
@testable import CmuxNextFloating
import Testing

/// Start Agent from Any App summons the Quick Composer over the frontmost app without activating
/// or unhiding cmux. With cmux hidden (⌘H, Hide Others), a window that hides with its app would stay
/// hidden; the panel doesn't, so it shows without bringing back every main window.
@MainActor @Suite struct QuickComposerPanelTests {
    @Test func theQuickComposerShowsWhileCmuxIsHidden() {
        let panel = QuickComposerPanel()
        #expect(!panel.canHide)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    /// A page that records every size it is given.
    final class SizeRecordingView: NSView {
        var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    /// Feature `windowFrameAnimationHoldsContent` on: folding the
    /// floating chat animates the panel's frame, but its page keeps its size until the frame lands
    /// and then resizes once, instead of a page layout at every step of the animation.
    @Test func aFoldResizesThePageOnceWhenTheFrameLands() throws {
        _ = NSApplication.shared
        let panel = QuickComposerPanel(holdsContentInMotion: true)
        defer { panel.orderOut(nil) }
        let page = SizeRecordingView()
        panel.present(page, focus: nil)
        let parent = try #require(page.superview, "the page is not in the panel")
        page.sizes.removeAll()
        panel.setCollapsed(true)
        let end = Date(timeIntervalSinceNow: 2)
        while page.frame.size != parent.bounds.size || abs(panel.frame.height - FloatingChatFrames.barHeight) > 0.5, Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(abs(panel.frame.height - FloatingChatFrames.barHeight) <= 0.5, "the fold did not land: \(panel.frame)")
        #expect(page.frame.size == parent.bounds.size, "the page \(page.frame) does not fill the panel \(parent.bounds)")
        #expect(page.sizes.count == 1, "the page resized \(page.sizes.count) times during the fold: \(page.sizes)")
        #expect(page.autoresizingMask == [.width, .height], "the page no longer follows the panel's size")
    }

    /// Feature `windowFrameAnimationHoldsContent` off (its default): the fold holds nothing; at
    /// every step the page fills the panel.
    @Test func withTheHoldOffThePageFollowsThePanelThroughAFold() throws {
        _ = NSApplication.shared
        let panel = QuickComposerPanel()
        defer { panel.orderOut(nil) }
        let page = SizeRecordingView()
        panel.present(page, focus: nil)
        let parent = try #require(page.superview, "the page is not in the panel")
        let mask = page.autoresizingMask
        panel.setCollapsed(true)
        #expect(panel.frameHold.open == 0, "the fold opened a page hold with the feature off")
        let end = Date(timeIntervalSinceNow: 2)
        while abs(panel.frame.height - FloatingChatFrames.barHeight) > 0.5, Date() < end {
            #expect(page.autoresizingMask == mask, "the page stopped following the panel mid-fold")
            #expect(page.frame.size == parent.bounds.size, "the page \(page.frame) lags the panel \(parent.bounds) mid-fold")
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(abs(panel.frame.height - FloatingChatFrames.barHeight) <= 0.5, "the fold did not land: \(panel.frame)")
        #expect(page.frame.size == parent.bounds.size, "the page \(page.frame) does not fill the panel \(parent.bounds)")
    }

    /// The chat released while the panel still moves into the floating chat (Cmd-Return during the
    /// move): the move does not land later, so the next composer opens at the composer's size, not
    /// the floating chat's.
    @Test(.enabled(if: NSScreen.main != nil, "the floating chat needs a screen: run on a GUI host"))
    func releasingTheChatMidMoveKeepsTheComposerSize() {
        _ = NSApplication.shared
        let panel = QuickComposerPanel(holdsContentInMotion: true)
        defer { panel.orderOut(nil) }
        panel.present(NSView(), focus: nil)
        panel.holdChat(true)
        panel.holdChat(false)
        let end = Date(timeIntervalSinceNow: 1)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(panel.contentRect(forFrameRect: panel.frame).size == QuickComposerPanel.size,
                "a late floating chat move sized the composer: \(panel.frame)")
        #expect(panel.frameHold.open == 0, "the taken-over move kept its hold")
    }
}
