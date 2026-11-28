import AppKit
import CoreGraphics
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
final class CanvasPaneDelegateSpy: CanvasPaneViewDelegate {
    var focusRequests: [CanvasPaneID] = []

    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion) {}
    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func paneViewDidEndDrag(_ view: CanvasPaneView) {}
    func paneView(_ view: CanvasPaneView, requestTearOutTab panelId: UUID, atDocumentPoint point: CGPoint) {}
    func paneView(_ view: CanvasPaneView, didSelectTab panelId: UUID) {}
    func paneView(_ view: CanvasPaneView, didCloseTab panelId: UUID) {}

    func paneViewDidRequestFocus(_ view: CanvasPaneView) {
        focusRequests.append(view.paneID)
    }
}
