public import CoreGraphics

/// The occlusion holes a child-window page needs for the overlays above it.
///
/// Pure: given the page content view's rect and each shown overlay's rect
/// (both in window coordinates), the holes in the content view's coordinates.
/// An overlay outside the page makes no hole; an overlay partly outside makes
/// a hole only where it covers the page; a hole inside another hole is
/// dropped, because the fork masks with even-odd rules and a nested hole would
/// show the page again (Next `CEFHostView.outermost`).
public struct BrowserPageOcclusionPlan: Equatable, Sendable {
    /// The page content view's bounds in window coordinates.
    public var contentRectInWindow: CGRect
    /// Each shown overlay's frame in window coordinates.
    public var overlayRectsInWindow: [CGRect]

    public init(contentRectInWindow: CGRect, overlayRectsInWindow: [CGRect]) {
        self.contentRectInWindow = contentRectInWindow
        self.overlayRectsInWindow = overlayRectsInWindow
    }

    /// The holes, in the content view's coordinates (origin at the content
    /// view's bottom-left, as AppKit's unflipped `convert(_:from: nil)`).
    public var holes: [CGRect] {
        let local = overlayRectsInWindow.compactMap { rect -> CGRect? in
            let clipped = rect.intersection(contentRectInWindow)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return clipped.offsetBy(dx: -contentRectInWindow.minX, dy: -contentRectInWindow.minY).integral
        }
        return Self.outermost(local)
    }

    /// `rects` without those inside another (of equal rects the first stays).
    static func outermost(_ rects: [CGRect]) -> [CGRect] {
        rects.enumerated().filter { index, rect in
            !rects.enumerated().contains { other, outer in
                other != index && outer.contains(rect) && (outer != rect || other < index)
            }
        }.map(\.element)
    }
}
