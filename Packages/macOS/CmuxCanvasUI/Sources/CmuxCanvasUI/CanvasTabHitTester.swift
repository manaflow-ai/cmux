import CoreGraphics
import Foundation

struct CanvasTabHitTester {
    var tabOrder: [UUID]
    var hitRegions: CanvasTabHitRegions

    func tab(at point: CGPoint) -> UUID? {
        tabOrder.first { tabId in
            hitRegions.tabFrames[tabId]?.contains(point) == true
        }
    }

    func closeTab(at point: CGPoint, hoveredTabId: UUID?) -> UUID? {
        guard let hoveredTabId,
              hitRegions.closeFrames[hoveredTabId]?.contains(point) == true else {
            return nil
        }
        return hoveredTabId
    }
}
