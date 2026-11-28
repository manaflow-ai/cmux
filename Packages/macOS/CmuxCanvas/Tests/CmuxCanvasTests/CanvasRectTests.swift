import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasRectTests {
    @Test func edgesAndCenter() {
        let rect = CanvasRect(x: 10, y: 20, width: 100, height: 50)
        #expect(rect.minX == 10)
        #expect(rect.maxX == 110)
        #expect(rect.midX == 60)
        #expect(rect.minY == 20)
        #expect(rect.maxY == 70)
        #expect(rect.midY == 45)
        #expect(rect.center == CanvasPoint(x: 60, y: 45))
    }

    @Test func offsetAndExpand() {
        let rect = CanvasRect(x: 0, y: 0, width: 10, height: 10)
        #expect(rect.offsetBy(dx: 5, dy: -5) == CanvasRect(x: 5, y: -5, width: 10, height: 10))
        #expect(rect.expandedBy(2) == CanvasRect(x: -2, y: -2, width: 14, height: 14))
        #expect(rect.expandedBy(-2) == CanvasRect(x: 2, y: 2, width: 6, height: 6))
    }

    @Test func intersectionRequiresPositiveArea() {
        let a = CanvasRect(x: 0, y: 0, width: 10, height: 10)
        #expect(a.intersects(CanvasRect(x: 5, y: 5, width: 10, height: 10)))
        // Edge-touching rects do not intersect.
        #expect(!a.intersects(CanvasRect(x: 10, y: 0, width: 10, height: 10)))
        #expect(!a.intersects(CanvasRect(x: 0, y: 10, width: 10, height: 10)))
        #expect(!a.intersects(CanvasRect(x: 20, y: 20, width: 5, height: 5)))
    }

    @Test func containsIsClosedOpenPerAxis() {
        let rect = CanvasRect(x: 0, y: 0, width: 10, height: 10)
        #expect(rect.contains(CanvasPoint(x: 0, y: 0)))
        #expect(rect.contains(CanvasPoint(x: 9.99, y: 9.99)))
        #expect(!rect.contains(CanvasPoint(x: 10, y: 5)))
        #expect(!rect.contains(CanvasPoint(x: 5, y: 10)))
        #expect(!rect.contains(CanvasPoint(x: -0.01, y: 5)))
    }

    @Test func unionCoversBothRects() {
        let a = CanvasRect(x: 0, y: 0, width: 10, height: 10)
        let b = CanvasRect(x: 30, y: -5, width: 5, height: 5)
        #expect(a.union(b) == CanvasRect(x: 0, y: -5, width: 35, height: 15))
    }
}
