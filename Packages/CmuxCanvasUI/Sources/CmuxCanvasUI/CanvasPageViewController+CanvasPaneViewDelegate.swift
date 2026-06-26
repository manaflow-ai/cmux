import AppKit
import CmuxCanvas

extension CanvasPageViewController: CanvasPaneViewDelegate {
    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion) {}

    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {}

    func paneViewDidEndDrag(_ view: CanvasPaneView) {}

    func paneView(_ view: CanvasPaneView, requestTearOutTab panelId: UUID, atDocumentPoint point: CGPoint) {}

    func paneView(_ view: CanvasPaneView, didSelectTab panelId: UUID) {
        owner?.selectTab(panelId)
    }

    func paneView(_ view: CanvasPaneView, didCloseTab panelId: UUID) {
        owner?.closeTab(panelId)
    }

    func paneViewDidRequestFocus(_ view: CanvasPaneView) {
        owner?.focusPage(for: view.paneID)
    }
}
