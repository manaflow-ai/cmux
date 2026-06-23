import Testing
@testable import CmuxCanvas

import Foundation

struct CanvasLayoutTests {
    private func id(_ value: UInt8) -> CanvasPaneID {
        CanvasPaneID(rawValue: UUID(uuid: (
            value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )))
    }

    @Test func addRemoveAndLookup() {
        var layout = CanvasLayout()
        #expect(layout.isEmpty)
        let a = id(1)
        layout.add(CanvasPane(id: a, frame: CanvasRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(layout.contains(a))
        #expect(layout.frame(of: a) == CanvasRect(x: 0, y: 0, width: 100, height: 100))
        layout.remove(a)
        #expect(!layout.contains(a))
        #expect(layout.frame(of: a) == nil)
    }

    @Test func addingExistingPaneReplacesAndRaises() {
        var layout = CanvasLayout()
        let a = id(1)
        let b = id(2)
        layout.add(CanvasPane(id: a, frame: CanvasRect(x: 0, y: 0, width: 10, height: 10)))
        layout.add(CanvasPane(id: b, frame: CanvasRect(x: 20, y: 0, width: 10, height: 10)))
        layout.add(CanvasPane(id: a, frame: CanvasRect(x: 40, y: 0, width: 10, height: 10)))
        #expect(layout.panes.count == 2)
        #expect(layout.paneIDs == [b, a])
        #expect(layout.frame(of: a) == CanvasRect(x: 40, y: 0, width: 10, height: 10))
    }

    @Test func zOrderAndBringToFront() {
        var layout = CanvasLayout()
        let a = id(1)
        let b = id(2)
        let c = id(3)
        for (paneID, x) in [(a, 0.0), (b, 10.0), (c, 20.0)] {
            layout.add(CanvasPane(id: paneID, frame: CanvasRect(x: x, y: 0, width: 10, height: 10)))
        }
        layout.bringToFront(a)
        #expect(layout.paneIDs == [b, c, a])
        // Raising the front pane keeps order.
        layout.bringToFront(a)
        #expect(layout.paneIDs == [b, c, a])
    }

    @Test func topPaneHitTestsFrontFirst() {
        var layout = CanvasLayout()
        let back = id(1)
        let front = id(2)
        layout.add(CanvasPane(id: back, frame: CanvasRect(x: 0, y: 0, width: 100, height: 100)))
        layout.add(CanvasPane(id: front, frame: CanvasRect(x: 50, y: 50, width: 100, height: 100)))
        #expect(layout.topPane(at: CanvasPoint(x: 75, y: 75)) == front)
        #expect(layout.topPane(at: CanvasPoint(x: 10, y: 10)) == back)
        #expect(layout.topPane(at: CanvasPoint(x: 500, y: 500)) == nil)
    }

    @Test func contentBoundsUnionsAllPanes() {
        var layout = CanvasLayout()
        #expect(layout.contentBounds == nil)
        layout.add(CanvasPane(id: id(1), frame: CanvasRect(x: -10, y: 0, width: 20, height: 20)))
        layout.add(CanvasPane(id: id(2), frame: CanvasRect(x: 100, y: -50, width: 30, height: 30)))
        #expect(layout.contentBounds == CanvasRect(x: -10, y: -50, width: 140, height: 70))
    }

    @Test func setFramesAppliesBatchAndIgnoresUnknownIDs() {
        var layout = CanvasLayout()
        let a = id(1)
        layout.add(CanvasPane(id: a, frame: CanvasRect(x: 0, y: 0, width: 10, height: 10)))
        layout.setFrames([
            a: CanvasRect(x: 5, y: 5, width: 10, height: 10),
            id(9): CanvasRect(x: 99, y: 99, width: 1, height: 1),
        ])
        #expect(layout.frame(of: a) == CanvasRect(x: 5, y: 5, width: 10, height: 10))
        #expect(layout.panes.count == 1)
    }

    @Test func codableRoundTripPreservesOrderAndFrames() throws {
        var layout = CanvasLayout()
        layout.add(CanvasPane(id: id(3), frame: CanvasRect(x: 1.5, y: -2.25, width: 320, height: 240)))
        layout.add(CanvasPane(id: id(1), frame: CanvasRect(x: 400, y: 0, width: 100, height: 100)))
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(CanvasLayout.self, from: data)
        #expect(decoded == layout)
        #expect(decoded.paneIDs == layout.paneIDs)
    }
}
