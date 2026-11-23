@testable import CmuxTabsKit
import CoreGraphics
import Testing

struct AccessoryTraceTests {
    /// The row as AccessoryZoom draws it over a zoom's progress values.
    private func trace(_ progress: [Double]) -> AccessoryTrace {
        let path = ZoomRectPath(full: CGRect(x: 0, y: 0, width: 400, height: 800), card: CGRect(x: 20, y: 100, width: 180, height: 360))
        var t = AccessoryTrace()
        for p in progress {
            let z = AccessoryZoom.presentation(phase: .animating, progress: p, offset: .zero, path: path)
            t.note(opacity: z.opacity, scale: Double(z.scale))
        }
        return t
    }

    @Test func rowThatRidesTheZoomPasses() {
        let ramp = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
        let toGrid = trace(ramp).summary(toOverview: true)
        #expect(toGrid.ridesZoom && toGrid.firstOpacity == 1 && toGrid.lastOpacity == 0 && toGrid.midFades > 0)
        #expect(toGrid.lastScale < toGrid.firstScale)
        let toPage = trace(ramp.reversed().map { $0 } + [0.02]).summary(toOverview: false)
        #expect(toPage.ridesZoom)
    }

    @Test func rowRemovedWhenTheZoomStartsFails() {
        // No samples: the row left the screen with the tap.
        #expect(!AccessoryTrace().summary(toOverview: true).ridesZoom)
        #expect(!AccessoryTrace().summary(toOverview: false).ridesZoom)
        // Drawn but popped out in one frame, never part-faded.
        var popped = AccessoryTrace()
        for (o, s) in [(1.0, 1.0), (0.0, 0.9), (0.0, 0.8), (0.0, 0.7)] { popped.note(opacity: o, scale: s) }
        #expect(!popped.summary(toOverview: true).ridesZoom)
        // Faded but never scaled with the page.
        var still = AccessoryTrace()
        for o in [1.0, 0.6, 0.3, 0.0] { still.note(opacity: o, scale: 1) }
        #expect(!still.summary(toOverview: true).ridesZoom)
    }
}
