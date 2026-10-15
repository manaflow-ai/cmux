public import CoreGraphics

/// The occlusion holes a child-window page needs for the overlays above it.
///
/// Pure: given the page content view's bounds and each shown overlay's frame,
/// both already in the content view's own coordinates (`convert(_:from:)`,
/// so a flipped view or a bounds offset is handled by AppKit), the holes. An
/// overlay outside the page makes no hole; an overlay partly outside makes a
/// hole only where it covers the page; a hole inside another hole is dropped,
/// because the fork masks with even-odd rules and a nested hole would show
/// the page again (Next `CEFHostView.outermost`).
public struct BrowserPageOcclusionPlan: Equatable, Sendable {
    /// The page content view's bounds.
    public var contentBounds: CGRect
    /// Each shown overlay's frame, in the content view's coordinates.
    public var overlayRects: [CGRect]

    public init(contentBounds: CGRect, overlayRects: [CGRect]) {
        self.contentBounds = contentBounds
        self.overlayRects = overlayRects
    }

    /// The holes, in the content view's coordinates, rounded outward to whole points.
    public var holes: [CGRect] {
        let clipped = overlayRects.compactMap { rect -> CGRect? in
            let clipped = rect.intersection(contentBounds)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return clipped.integral
        }
        return Self.outermost(clipped)
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
