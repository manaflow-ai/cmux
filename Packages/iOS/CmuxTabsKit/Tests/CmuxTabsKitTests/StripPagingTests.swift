@testable import CmuxTabsKit
import CoreGraphics
import Testing

struct StripPagingTests {
    /// Chips of 176, 75 and 150 pt, 10 pt apart, on a 362 pt strip whose anchor (the screen's
    /// center) is 181 pt in.
    private let paging = StripPaging(widths: [176, 75, 150], gap: 10, anchor: 181, viewport: 362)

    @Test func firstPageIsOffsetZeroAndEachChipCentersOnTheAnchor() {
        #expect(paging.offset(0) == 0)
        for i in 0..<paging.count {
            #expect(abs(paging.center(i) - paging.offset(i) - paging.anchor) < 0.001)
        }
        // The last page is the end of the row.
        #expect(abs(paging.offset(2) - (paging.contentWidth - paging.viewport)) < 0.001)
    }

    @Test func positionIsFractionalBetweenPages() {
        #expect(paging.position(offset: paging.offset(1)) == 1)
        let mid = (paging.offset(1) + paging.offset(2)) / 2
        #expect(abs(paging.position(offset: mid) - 1.5) < 0.001)
        // Rubber-banding before the first page and past the last.
        #expect(paging.position(offset: -20) < 0)
        #expect(paging.position(offset: paging.offset(2) + 20) > 2)
    }

    @Test func releasePagesAtMostOneChip() {
        // A fling far past two pages still turns one.
        #expect(paging.target(start: 0, projected: paging.offset(2) + 400, velocity: 3000) == 1)
        #expect(paging.target(start: 2, projected: -400, velocity: -3000) == 1)
        // A slow release under half way springs back; past half way pages.
        let quarter = paging.offset(0) + (paging.offset(1) - paging.offset(0)) * 0.25
        #expect(paging.target(start: 0, projected: quarter, velocity: 0) == 0)
        let threeQuarters = paging.offset(0) + (paging.offset(1) - paging.offset(0)) * 0.75
        #expect(paging.target(start: 0, projected: threeQuarters, velocity: 0) == 1)
        // Never before the first page or past the last.
        #expect(paging.target(start: 0, projected: -300, velocity: -3000) == 0)
        #expect(paging.target(start: 2, projected: 900, velocity: 3000) == 2)
    }

    @Test func oneChipCentersAndStays() {
        let one = StripPaging(widths: [90], gap: 10, anchor: 181, viewport: 362)
        #expect(one.offset(0) == 0)
        #expect(one.leadingPad == 136)
        #expect(one.target(start: 0, projected: 50, velocity: 2000) == 0)
    }

    @Test func theRowStopsAtEitherEnd() {
        #expect(StripPaging.clamp(50, low: 0, high: 100) == 50)
        #expect(StripPaging.clamp(-100, low: 0, high: 100) == 0)
        #expect(StripPaging.clamp(200, low: 0, high: 100) == 100)
    }

    @Test func aChipLeavesRoomForItsNeighbors() {
        // A 258 pt strip (iPhone 17 Pro): a neighbor shows 36 pt on each side.
        #expect(StripPaging.chipMaxWidth(viewport: 258, gap: 10, cap: 200) == 166)
        #expect(StripPaging.chipMaxWidth(viewport: 600, gap: 10, cap: 200) == 200)
    }
}
