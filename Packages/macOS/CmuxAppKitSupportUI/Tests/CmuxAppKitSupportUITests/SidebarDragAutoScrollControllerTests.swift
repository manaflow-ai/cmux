import AppKit
import Testing
@testable import CmuxAppKitSupportUI

@MainActor
private final class PopulatedTableDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 200 }
}

@MainActor
struct SidebarDragAutoScrollControllerTests {
    private let tableDataSource = PopulatedTableDataSource()

    private func makeScrolledScrollView(offsetY: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace")))
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.dataSource = tableDataSource
        scrollView.documentView = tableView
        tableView.reloadData()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offsetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    /// Regression: converted pointer positions are document coordinates whose
    /// origin is the scroll offset. Distances measured without removing that
    /// offset made every mid-list position past one viewport height read as
    /// "at the bottom edge", planning max-speed downward scrolling that never
    /// stopped while the pointer sat nowhere near an edge.
    @Test
    func midViewportPointerPlansNothingWhenScrolledDeep() {
        let controller = SidebarDragAutoScrollController()
        let scrollView = makeScrolledScrollView(offsetY: 2000)
        let clipView = scrollView.contentView

        let midViewport = CGPoint(x: 100, y: clipView.bounds.origin.y + 200)
        #expect(controller.planForMousePoint(midViewport, in: clipView) == nil)
    }

    @Test
    func edgePointersPlanTheMatchingDirectionWhenScrolledDeep() {
        let controller = SidebarDragAutoScrollController()
        let scrollView = makeScrolledScrollView(offsetY: 2000)
        let clipView = scrollView.contentView

        let nearTop = CGPoint(x: 100, y: clipView.bounds.origin.y + 10)
        #expect(controller.planForMousePoint(nearTop, in: clipView)?.direction == .up)
        let aboveTop = CGPoint(x: 100, y: clipView.bounds.origin.y - 10)
        #expect(controller.planForMousePoint(aboveTop, in: clipView)?.direction == .up)

        let nearBottom = CGPoint(x: 100, y: clipView.bounds.origin.y + clipView.bounds.height - 10)
        #expect(controller.planForMousePoint(nearBottom, in: clipView)?.direction == .down)
    }

    @Test
    func edgePointersOutsideTheViewportWidthPlanNothing() {
        let controller = SidebarDragAutoScrollController()
        let scrollView = makeScrolledScrollView(offsetY: 2000)
        let clipView = scrollView.contentView
        let nearTopY = clipView.bounds.origin.y + 10

        let leftOfViewport = CGPoint(x: clipView.bounds.minX - 1, y: nearTopY)
        #expect(controller.planForMousePoint(leftOfViewport, in: clipView) == nil)

        let rightOfViewport = CGPoint(x: clipView.bounds.maxX + 1, y: nearTopY)
        #expect(controller.planForMousePoint(rightOfViewport, in: clipView) == nil)
    }

    @Test
    func plansProduceMatchingDeltasForARealFlippedTable() {
        let scrollView = makeScrolledScrollView(offsetY: 2000)
        let clipView = scrollView.contentView
        let tableView = scrollView.documentView as? NSTableView

        #expect(clipView.isFlipped)
        #expect(tableView?.isFlipped == true)
        #expect(
            SidebarAutoScrollPlan(direction: .up, pointsPerTick: 12).verticalDelta(
                documentViewIsFlipped: tableView?.isFlipped == true
            ) == -12
        )
        #expect(
            SidebarAutoScrollPlan(direction: .down, pointsPerTick: 12).verticalDelta(
                documentViewIsFlipped: tableView?.isFlipped == true
            ) == 12
        )
    }
}
