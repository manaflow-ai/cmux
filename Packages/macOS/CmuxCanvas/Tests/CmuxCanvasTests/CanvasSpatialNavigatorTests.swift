import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasSpatialNavigatorTests {
    private let navigator = CanvasSpatialNavigator()

    private func id(_ value: UInt8) -> CanvasPaneID {
        CanvasPaneID(rawValue: UUID(uuid: (
            value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )))
    }

    private func layout(_ frames: [(UInt8, CanvasRect)]) -> CanvasLayout {
        var layout = CanvasLayout()
        for (value, frame) in frames {
            layout.add(CanvasPane(id: id(value), frame: frame))
        }
        return layout
    }

    @Test func findsNearestInEachDirection() {
        // A plus-shaped arrangement around pane 0.
        let layout = layout([
            (0, CanvasRect(x: 300, y: 300, width: 100, height: 100)),
            (1, CanvasRect(x: 100, y: 300, width: 100, height: 100)),  // left
            (2, CanvasRect(x: 500, y: 300, width: 100, height: 100)),  // right
            (3, CanvasRect(x: 300, y: 100, width: 100, height: 100)),  // up
            (4, CanvasRect(x: 300, y: 500, width: 100, height: 100)),  // down
        ])
        #expect(navigator.pane(.left, from: id(0), in: layout) == id(1))
        #expect(navigator.pane(.right, from: id(0), in: layout) == id(2))
        #expect(navigator.pane(.up, from: id(0), in: layout) == id(3))
        #expect(navigator.pane(.down, from: id(0), in: layout) == id(4))
    }

    @Test func prefersOverlappingBandOverCloserMisalignedPane() {
        let layout = layout([
            (0, CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            // Closer on x but far below (no vertical overlap).
            (1, CanvasRect(x: 150, y: 400, width: 100, height: 100)),
            // Farther on x but vertically overlapping.
            (2, CanvasRect(x: 300, y: 20, width: 100, height: 100)),
        ])
        #expect(navigator.pane(.right, from: id(0), in: layout) == id(2))
    }

    @Test func returnsNilWhenNoPaneInDirection() {
        let layout = layout([
            (0, CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            (1, CanvasRect(x: 200, y: 0, width: 100, height: 100)),
        ])
        #expect(navigator.pane(.left, from: id(0), in: layout) == nil)
        #expect(navigator.pane(.right, from: id(1), in: layout) == nil)
    }

    @Test func returnsNilForUnknownOrigin() {
        let layout = layout([(0, CanvasRect(x: 0, y: 0, width: 100, height: 100))])
        #expect(navigator.pane(.left, from: id(9), in: layout) == nil)
    }

    @Test func tieBreaksDeterministicallyById() {
        // Two identical candidates equidistant to the right.
        let layout = layout([
            (0, CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            (5, CanvasRect(x: 200, y: 110, width: 100, height: 100)),
            (3, CanvasRect(x: 200, y: -110, width: 100, height: 100)),
        ])
        #expect(navigator.pane(.right, from: id(0), in: layout) == id(3))
    }

    @Test func sideBySidePanesNavigateDespiteCenterProximity() {
        // Wide pane next to a narrow one whose center is barely to the right.
        let layout = layout([
            (0, CanvasRect(x: 0, y: 0, width: 600, height: 100)),
            (1, CanvasRect(x: 616, y: 0, width: 100, height: 100)),
        ])
        #expect(navigator.pane(.right, from: id(0), in: layout) == id(1))
        #expect(navigator.pane(.left, from: id(1), in: layout) == id(0))
    }
}
