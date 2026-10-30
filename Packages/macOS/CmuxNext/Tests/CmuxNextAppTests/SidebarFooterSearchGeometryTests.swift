import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Footer Search geometry stays reachable in every pinned-row shape: empty, fitting, and overfull.
@MainActor @Suite(.serialized) struct SidebarFooterSearchGeometryTests {
    @Test(arguments: [160.0, 208.0] as [CGFloat])
    func emptyPinnedRowUsesTheSharedColumn(sidebarWidth: CGFloat) {
        let column = sidebarWidth - 20
        let placement = SidebarFooterBand.searchPlacement(columnX: column, sidebarWidth: sidebarWidth,
                                                           side: 24, itemsMaxX: nil)
        #expect(!placement.needsDedicatedRow)
        #expect(placement.x == column - 12)
    }

    @Test func presentPinnedRowThatFitsStaysOnItsSharedColumn() {
        let placement = SidebarFooterBand.searchPlacement(columnX: 180, sidebarWidth: 208,
                                                           side: 24, itemsMaxX: 120)
        #expect(!placement.needsDedicatedRow)
        #expect(placement.x == 168)
    }

    @Test func overfullPinnedRowGetsAReachableDedicatedFooterLine() {
        let placement = SidebarFooterBand.searchPlacement(columnX: 140, sidebarWidth: 160,
                                                           side: 24, itemsMaxX: 150)
        #expect(placement.needsDedicatedRow)
        #expect(placement.x == 136)
        #expect(placement.x + 24 <= 160)
    }

    @Test func widePinnedRowStillLeavesSearchInsideTheSidebar() {
        let placement = SidebarFooterBand.searchPlacement(columnX: 340, sidebarWidth: 360,
                                                           side: 24, itemsMaxX: 330)
        #expect(placement.needsDedicatedRow)
        #expect(placement.x + 24 <= 360)
    }
}
