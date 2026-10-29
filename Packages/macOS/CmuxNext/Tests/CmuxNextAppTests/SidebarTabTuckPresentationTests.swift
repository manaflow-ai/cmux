import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// The compositor can sample just before an explicitly timed fade begins. The row's model
/// opacity is already zero then: it must still show the starting opacity, not blink off and back on.
@MainActor @Suite(.serialized)
struct SidebarTabTuckPresentationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func foldingOpacityNeverRisesAfterAnInitiallyBlankFrame() async throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let enabled = design.animationsEnabled, disabled = design.disabledAnimationCategories
        let speed = design.animationSpeed, reduced = Motion.reduceMotionOverride
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .normal
        Motion.reduceMotionOverride = false
        defer {
            design.animationsEnabled = enabled
            design.disabledAnimationCategories = disabled
            design.animationSpeed = speed
            Motion.reduceMotionOverride = reduced
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let line = SidebarRowView(key: .tab(WorkspaceID("tuck-presentation"), TabID("tab")))
        line.frame = NSRect(x: 0, y: 26, width: 200, height: 24)
        window.contentView?.addSubview(line)
        window.orderFront(nil)
        window.displayIfNeeded()
        CATransaction.flush()

        _ = RowMotion.tuck(appearing: [], leaving: [(line, line.frame.offsetBy(dx: 0, dy: -26))])
        let layer = try #require(line.layer)
        let fade = try #require(layer.animation(forKey: RowMotion.tuckKey) as? CAKeyframeAnimation)
        let gone = try #require(fade.keyTimes?[1].doubleValue)
        // Freeze the real layer's clock at three compositor sample times. No hand-written
        // animation evaluator: presentation() must supply the opacity Core Animation draws.
        layer.speed = 0
        var shown: [Float] = []
        for offset in [-1.0 / 120, fade.duration * gone / 2, fade.duration * gone] {
            layer.timeOffset = fade.beginTime + offset
            CATransaction.flush()
            // Let the window server consume this fixed clock; the sample does not depend on elapsed time.
            try await Task.sleep(for: .milliseconds(50))
            shown.append(try #require(layer.presentation()).opacity)
        }
        #expect(shown[0] > 0.99, "the first compositor sample was blank: \(shown)")
        #expect(shown[1] > 0.05 && shown[1] < shown[0], "the fade reappeared or never ran: \(shown)")
        #expect(shown[2] < 0.01, "the existing early-fade deadline moved: \(shown)")
        RowMotion.untuck([line])
    }
}
