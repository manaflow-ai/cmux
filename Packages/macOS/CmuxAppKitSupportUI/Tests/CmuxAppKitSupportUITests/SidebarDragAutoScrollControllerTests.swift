import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct SidebarDragAutoScrollControllerTests {
    @MainActor
    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    @MainActor
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor
    @Test func plansAgainstScrolledViewportBounds() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.documentView = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 1_000))
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: 300))

        let controller = SidebarDragAutoScrollController()
        let middlePlan = controller.planForMousePoint(
            NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY),
            in: clipView
        )
        let topPlan = controller.planForMousePoint(
            NSPoint(x: clipView.bounds.midX, y: clipView.bounds.minY + 4),
            in: clipView
        )
        let bottomPlan = controller.planForMousePoint(
            NSPoint(x: clipView.bounds.midX, y: clipView.bounds.maxY - 4),
            in: clipView
        )

        #expect(middlePlan == nil)
        #expect(try #require(topPlan).direction == .up)
        #expect(try #require(bottomPlan).direction == .down)
    }

    @MainActor
    @Test func repeatedTicksReachBothConstrainedBoundsWithoutOvershoot() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let clipView = FlippedClipView(frame: scrollView.bounds)
        scrollView.contentView = clipView
        scrollView.documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 1_000)
        )

        let controller = SidebarDragAutoScrollController()
        let up = SidebarAutoScrollPlan(direction: .up, pointsPerTick: 12)
        let down = SidebarAutoScrollPlan(direction: .down, pointsPerTick: 12)
        let topBounds = clipView.constrainBoundsRect(
            NSRect(x: 0, y: -10_000, width: clipView.bounds.width, height: clipView.bounds.height)
        )
        let bottomBounds = clipView.constrainBoundsRect(
            NSRect(x: 0, y: 10_000, width: clipView.bounds.width, height: clipView.bounds.height)
        )

        clipView.scroll(to: NSPoint(x: 0, y: 300))
        #expect(controller.apply(plan: up, to: scrollView))
        #expect(clipView.bounds.minY == 288)
        #expect(controller.apply(plan: down, to: scrollView))
        #expect(clipView.bounds.minY == 300)

        var downwardTicks = 0
        while controller.apply(plan: down, to: scrollView) {
            downwardTicks += 1
            #expect(downwardTicks < 1_000)
        }
        #expect(downwardTicks > 0)
        #expect(abs(clipView.bounds.minY - bottomBounds.minY) < 0.01)
        #expect(!controller.apply(plan: down, to: scrollView))

        var upwardTicks = 0
        while controller.apply(plan: up, to: scrollView) {
            upwardTicks += 1
            #expect(upwardTicks < 1_000)
        }
        #expect(upwardTicks > 0)
        #expect(abs(clipView.bounds.minY - topBounds.minY) < 0.01)
        #expect(!controller.apply(plan: up, to: scrollView))
    }
}
