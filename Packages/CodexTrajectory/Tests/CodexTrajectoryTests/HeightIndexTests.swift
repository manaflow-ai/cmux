import CoreGraphics
import XCTest
@testable import CodexTrajectory

final class HeightIndexTests: XCTestCase {
    func testPrefixSumsAndOffsetLookup() {
        let index = CodexTrajectoryHeightIndex(heights: [10, 20, 30, 40])

        XCTAssertEqual(index.count, 4)
        XCTAssertEqual(index.totalHeight, 100)
        XCTAssertEqual(index.prefixSum(upTo: 0), 0)
        XCTAssertEqual(index.prefixSum(upTo: 2), 30)
        XCTAssertEqual(index.prefixSum(upTo: 4), 100)
        XCTAssertEqual(index.index(containingOffset: 0), 0)
        XCTAssertEqual(index.index(containingOffset: 9.9), 0)
        XCTAssertEqual(index.index(containingOffset: 10), 1)
        XCTAssertEqual(index.index(containingOffset: 29.9), 1)
        XCTAssertEqual(index.index(containingOffset: 30), 2)
        XCTAssertEqual(index.index(containingOffset: 99), 3)
        XCTAssertEqual(index.index(containingOffset: 500), 3)
    }

    func testAppendAndUpdateRemainLogicallyConsistent() {
        var index = CodexTrajectoryHeightIndex()
        for height in stride(from: CGFloat(1), through: CGFloat(10), by: CGFloat(1)) {
            index.append(height)
        }

        XCTAssertEqual(index.totalHeight, 55)
        XCTAssertEqual(index.prefixSum(upTo: 10), 55)
        XCTAssertEqual(index.index(containingOffset: 14.9), 4)

        index.update(index: 4, height: 50)
        XCTAssertEqual(index.totalHeight, 100)
        XCTAssertEqual(index.height(at: 4), 50)
        XCTAssertEqual(index.index(containingOffset: 14.9), 4)
        XCTAssertEqual(index.index(containingOffset: 59.9), 4)
        XCTAssertEqual(index.index(containingOffset: 60), 5)
    }

    func testVisibleRangeUsesOverscan() {
        let index = CodexTrajectoryHeightIndex(heights: Array(repeating: 10, count: 20))

        XCTAssertEqual(index.indexRange(intersectingOffset: 45, length: 30), 4..<8)
        XCTAssertEqual(index.indexRange(intersectingOffset: 45, length: 30, overscan: 15), 3..<9)
        XCTAssertEqual(index.indexRange(intersectingOffset: 0, length: 5), 0..<1)
    }

    func testVisibleRangeIncludesFractionalRowsAtUpperEdge() {
        let index = CodexTrajectoryHeightIndex(heights: [0.2, 0.2, 0.2])

        XCTAssertEqual(index.indexRange(intersectingOffset: 0, length: 0.4), 0..<2)
    }

    func testZeroHeightRowsMapPositiveOffsetsToFirstRow() {
        let index = CodexTrajectoryHeightIndex(heights: [0, 0, 0])

        XCTAssertEqual(index.totalHeight, 0)
        XCTAssertEqual(index.index(containingOffset: 5), 0)
    }

    func testLargeHeightIndexStressLookup() {
        let heights = (0..<50_000).map { CGFloat(($0 % 7) + 1) }
        let index = CodexTrajectoryHeightIndex(heights: heights)

        XCTAssertEqual(index.count, 50_000)
        XCTAssertEqual(index.totalHeight, heights.reduce(0, +))
        XCTAssertNotNil(index.index(containingOffset: index.totalHeight / 2))
        XCTAssertEqual(index.index(containingOffset: index.totalHeight + 1), 49_999)
    }
}
