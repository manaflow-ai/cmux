import AppKit
import CmuxNextDesign
@testable import CmuxNextFloating
import Foundation
import Testing

/// Holding a started chat moves the shown Quick Agent Chat to its floating column without holding
/// the main thread for the move. `setFrame(_:display:animate: true)` runs AppKit's whole resize
/// animation in a nested loop before it returns (no key, click, display-link callback or browser task
/// is served meanwhile): the panel glides on the run loop through the overlays' Motion gate instead,
/// as `setCollapsed` and the window zoom (`WindowZoom`) do. `check-motion.sh` refuses the blocking call.
@MainActor @Suite(.serialized) struct FloatingChatPlacementTests {
    private func shownPanel() throws -> (QuickComposerPanel, NSRect) {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main, "placing needs a screen")
        UserDefaults.standard.removeObject(forKey: FloatingChatFrames.key)
        let panel = QuickComposerPanel()
        let start = QuickComposerPanel.placement(size: QuickComposerPanel.size, in: screen.visibleFrame)
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        return (panel, start)
    }

    @Test(.enabled(if: NSScreen.main != nil, "placing needs a screen: run on a GUI host"))
    func holdingTheChatReturnsBeforeThePanelMoves() throws {
        let (panel, start) = try shownPanel()
        defer { panel.orderOut(nil); UserDefaults.standard.removeObject(forKey: FloatingChatFrames.key) }
        let animates = Motion.overlays.canAnimate(in: panel.contentView) && Motion.overlays.policy(in: panel).duration(.panel) > 0
        let began = Date()
        panel.holdChat(true)
        let ms = Date().timeIntervalSince(began) * 1000
        print("FloatingChatPlacementTests: holdChat(true) held the main thread \(String(format: "%.2f", ms)) ms "
            + "(animates=\(animates), frame after the call \(panel.frame), from \(start))")
        if animates {
            #expect(panel.frame == start, "the placement moved the panel inside its own call (\(panel.frame)): the animation held the main thread")
        }
        // Where it lands, not how fast: a 30 s hang guard for a loaded runner.
        let end = Date(timeIntervalSinceNow: 30)
        while abs(panel.frame.width - FloatingChatFrames.defaultSize.width) > 1, Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(abs(panel.frame.width - FloatingChatFrames.defaultSize.width) <= 1
                    && abs(panel.frame.height - FloatingChatFrames.defaultSize.height) <= 1,
                "the panel reached the floating column on the run loop: \(panel.frame)")
        #expect(abs(panel.frame.maxY - start.maxY) <= 1, "its top stays where the composer's was: \(panel.frame), from \(start)")
    }

    /// Hidden (a tab moved its chat here), the panel takes the floating frame at once: nothing to watch.
    @Test(.enabled(if: NSScreen.main != nil, "placing needs a screen: run on a GUI host"))
    func aHiddenPanelTakesItsFrameAtOnce() throws {
        let (panel, start) = try shownPanel()
        defer { UserDefaults.standard.removeObject(forKey: FloatingChatFrames.key) }
        panel.orderOut(nil)
        panel.holdChat(true)
        #expect(abs(panel.frame.width - FloatingChatFrames.defaultSize.width) <= 1, "a hidden panel is placed inside the call: \(panel.frame), from \(start)")
    }
}
