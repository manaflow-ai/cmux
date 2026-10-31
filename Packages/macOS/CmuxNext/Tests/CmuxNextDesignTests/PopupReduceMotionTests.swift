import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Reduce Motion keeps a popup's close to its fade (motion.md rule 7, motion pass 2026-10-12): the
/// group editors, the Feed and Notifications panels and the palette's actions menu shrink toward
/// their control while they fade out, and under Reduce Motion that shrink applied in one frame, so
/// the panel jumped 2% smaller and then faded. It now fades at its size.
@MainActor @Suite(.serialized, .closesItsWindows) struct PopupReduceMotionTests {
    @Test func aPopupClosingUnderReduceMotionFadesAtItsSize() throws {
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let layer = try #require(content.layer)
        window.alphaValue = 0
        window.openPopup(pivot: CGPoint(x: 150, y: 200))
        #expect(CATransform3DIsIdentity(layer.sublayerTransform))

        window.closePopup(pivot: CGPoint(x: 150, y: 200)) {}
        #expect(CATransform3DIsIdentity(layer.sublayerTransform), "the close scale applied at once")
        #expect(layer.animation(forKey: "sublayerTransform") == nil)
        window.resetPopupScale()
    }
}
