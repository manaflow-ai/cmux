import AppKit
import CoreGraphics
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("CanvasMinimapView")
struct CanvasMinimapViewTests {
    @Test func dragSettlesOnlyOnMouseUp() {
        let pane = CanvasMinimapPaneSnapshot(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let view = CanvasMinimapView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        view.snapshot = CanvasMinimapSnapshot(
            panes: [pane],
            visibleRect: CGRect(x: 100, y: 100, width: 200, height: 160),
            focusedPaneID: nil
        )
        var changedCenters: [CGPoint] = []
        var settledCenters: [CGPoint] = []
        view.onCenterChanged = { changedCenters.append($0) }
        view.onCenterSettled = { settledCenters.append($0) }

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 40, y: 40)))
        view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 80, y: 60)))

        #expect(changedCenters.count == 2)
        #expect(settledCenters.isEmpty)

        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 100, y: 70)))

        #expect(changedCenters.count == 2)
        #expect(settledCenters.count == 1)
    }

    private func mouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
