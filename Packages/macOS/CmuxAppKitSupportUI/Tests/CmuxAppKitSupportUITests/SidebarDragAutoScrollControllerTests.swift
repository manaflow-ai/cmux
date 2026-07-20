import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct SidebarDragAutoScrollControllerTests {
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
}
