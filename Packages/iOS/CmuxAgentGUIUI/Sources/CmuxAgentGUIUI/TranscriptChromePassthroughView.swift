#if os(iOS)
import UIKit

final class TranscriptChromePassthroughView: UIView {
    var bottomPassthroughHeight: CGFloat = 0
    weak var interactiveOverlayView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if let interactiveOverlayView,
           let result,
           result === interactiveOverlayView || result.isDescendant(of: interactiveOverlayView) {
            return result
        }
        let passthroughFrame = Self.bottomPassthroughFrame(
            bounds: bounds,
            keyboardTop: keyboardLayoutGuide.layoutFrame.minY,
            height: bottomPassthroughHeight
        )
        if passthroughFrame.contains(point) {
            return nil
        }
        return result === self ? nil : result
    }

    static func bottomPassthroughFrame(
        bounds: CGRect,
        keyboardTop: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let maxY = min(max(bounds.minY, keyboardTop), bounds.maxY)
        let minY = max(bounds.minY, maxY - max(0, height))
        return CGRect(x: bounds.minX, y: minY, width: bounds.width, height: maxY - minY)
    }
}
#endif
