import AppKit
import Testing
@testable import MessagesLabSidebar

/// cx-sya4n: nothing loops under Reduce Motion. The list observes no notification: after the
/// setting changes (the system's, or the host's pin `CmuxSidebarView.reduceMotionOverride`), the
/// host calls `applyReduceMotion()`, and a typing bubble already pulsing in the list stops, and
/// pulses again after Reduce Motion turns off.
@MainActor
@Suite(.serialized)
struct SidebarApplyReduceMotionTests {
    /// Whether `layer` or a layer under it runs a repeating animation.
    private static func loops(_ layer: CALayer) -> Bool {
        let own = (layer.animationKeys() ?? []).contains { key in
            guard let animation = layer.animation(forKey: key) else { return false }
            return animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0
        }
        return own || (layer.sublayers ?? []).contains(where: loops)
    }

    @Test func applyReduceMotionReachesATypingBubbleAlreadyPulsingInTheList() {
        defer { CmuxSidebarView.reduceMotionOverride = nil }
        CmuxSidebarView.reduceMotionOverride = false
        let list = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        list.wantsLayer = true
        let bubble = SidebarTypingLayer()
        list.layer?.addSublayer(bubble)
        bubble.animate()
        #expect(Self.loops(bubble), "the bubble should pulse before Reduce Motion")

        CmuxSidebarView.reduceMotionOverride = true
        list.applyReduceMotion()
        #expect(!Self.loops(bubble), "the bubble keeps pulsing after the host applied Reduce Motion")
        CmuxSidebarView.reduceMotionOverride = false
        list.applyReduceMotion()
        #expect(Self.loops(bubble), "the bubble does not pulse again after the host applied Reduce Motion off")
    }
}
