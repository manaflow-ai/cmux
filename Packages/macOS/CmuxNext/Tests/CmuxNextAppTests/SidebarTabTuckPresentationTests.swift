import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Before explicitly timed animations begin, the compositor must still show the starting
/// opacity AND frame. Holding only opacity exposes the destination frame over the workspace title.
@MainActor @Suite(.serialized)
struct SidebarTabTuckPresentationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"), arguments: [false, true])
    func foldingPresentationStartsAtTheVisibleFrame(resizing: Bool) async throws {
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

        let layer = try #require(line.layer)
        let startPosition = layer.position, startSize = layer.bounds.size
        var end = line.frame.offsetBy(dx: 0, dy: -26)
        if resizing { end.size.height /= 2 }
        _ = RowMotion.tuck(appearing: [], leaving: [(line, end)])
        // Match RowMotion.animate's outer transaction; test the actual spring installer.
        CATransaction.begin()
        SidebarDragSpring.move([(line, end)], in: try #require(window.contentView))
        CATransaction.commit()
        let fade = try #require(layer.animation(forKey: RowMotion.tuckKey) as? CAKeyframeAnimation)
        let springs = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
        let position = try #require(springs.first { $0.keyPath == "position" })
        if resizing { _ = try #require(springs.first { $0.keyPath == "bounds.size" }) }
        let gone = try #require(fade.keyTimes?[1].doubleValue)
        let first = min(fade.beginTime, position.beginTime)
        let last = max(fade.beginTime, position.beginTime)
        let endPosition = layer.position, endSize = layer.bounds.size
        // Freeze the real layer clock at the render-server start boundary, mid-fade, the
        // existing fade deadline and after settling. A full-speed composited recording is
        // also required: opacity-only sampling missed the destination-frame flash.
        layer.speed = 0
        var shown: [Float] = []
        var positions: [CGPoint] = [], sizes: [CGSize] = []
        for time in [first - 1.0 / 120, last + fade.duration * gone / 2,
                     last + fade.duration * gone, last + max(fade.duration, position.duration) + 0.1] {
            layer.timeOffset = time
            CATransaction.flush()
            // Let the window server consume this fixed clock; the sample does not depend on elapsed time.
            try await Task.sleep(for: .milliseconds(50))
            let presentation = try #require(layer.presentation())
            shown.append(presentation.opacity)
            positions.append(presentation.position)
            sizes.append(presentation.bounds.size)
        }
        #expect(abs(positions[0].y - startPosition.y) < 0.1, "the first frame jumped to the endpoint: \(positions)")
        #expect(abs(sizes[0].height - startSize.height) < 0.1, "the first frame jumped to the final size: \(sizes)")
        #expect(abs(positions[1].y - endPosition.y) < abs(startPosition.y - endPosition.y))
        #expect(abs(positions[1].y - endPosition.y) > 0.1, "the spring never moved: \(positions)")
        #expect(abs(positions[3].y - endPosition.y) < 0.1)
        #expect(abs(sizes[3].height - endSize.height) < 0.1)
        #expect(shown[0] > 0.99, "the first compositor sample was blank: \(shown)")
        #expect(shown[1] > 0.05 && shown[1] < shown[0], "the fade reappeared or never ran: \(shown)")
        #expect(shown[2] < 0.01, "the existing early-fade deadline moved: \(shown)")
        RowMotion.untuck([line])
    }
}
