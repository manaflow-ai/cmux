import AppKit
import SwiftUI

final class BrowserPortalOmnibarSuggestionsHostingView: NSHostingView<BrowserPortalOmnibarSuggestionsOverlay> {
    var popupFrameInTopLeftCoordinates: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes hit-test points in the superview's coordinate space.
        // Compare the popup frame in this hosting view's own top-left local
        // space so offset overlays and flipped hosting views route consistently.
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let topLeftPoint = isFlipped
            ? localPoint
            : NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
        guard popupFrameInTopLeftCoordinates.contains(topLeftPoint) else { return nil }
        return super.hitTest(point)
    }
}
