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
///
/// A rounded overlay (a card with corner radius r) gets a notched hole: three
/// non-overlapping rects (an edge band inset by r, the full-width middle, the
/// other edge band inset by r), so the page shows in its r x r corners instead
/// of a square of cmux's background behind the card (design spec §0.9).
public struct BrowserPageOcclusionPlan: Equatable, Sendable {
    /// One shown overlay: its frame in the content view's coordinates and its
    /// corner radius (0 for a square bar).
    public struct Overlay: Equatable, Sendable {
        public var rect: CGRect
        public var cornerRadius: CGFloat

        public init(rect: CGRect, cornerRadius: CGFloat = 0) {
            self.rect = rect
            self.cornerRadius = cornerRadius
        }
    }

    /// The page content view's bounds.
    public var contentBounds: CGRect
    /// Each shown overlay.
    public var overlays: [Overlay]

    public init(contentBounds: CGRect, overlays: [Overlay]) {
        self.contentBounds = contentBounds
        self.overlays = overlays
    }

    public init(contentBounds: CGRect, overlayRects: [CGRect]) {
        self.init(contentBounds: contentBounds, overlays: overlayRects.map { Overlay(rect: $0) })
    }

    /// The holes, in the content view's coordinates, on whole points.
    public var holes: [CGRect] {
        // Outermost first, by each overlay's whole frame, so a bar over a
        // full-page card does not cut a hole back into it.
        let shown = overlays.compactMap { overlay -> Overlay? in
            let clipped = overlay.rect.intersection(contentBounds)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return Overlay(rect: overlay.rect.integral, cornerRadius: overlay.cornerRadius)
        }
        let kept = Self.outermost(shown.map(\.rect))
        var used = Set<Int>()
        return kept.flatMap { rect -> [CGRect] in
            guard let index = shown.indices.first(where: { !used.contains($0) && shown[$0].rect == rect }) else { return [] }
            used.insert(index)
            return Self.notched(rect, radius: shown[index].cornerRadius)
                .map { $0.intersection(contentBounds) }
                .filter { !$0.isNull && !$0.isEmpty }
        }
    }

    /// `rect` as three non-overlapping rects that leave its r x r corners
    /// out; `rect` itself for no radius or a rect too small to notch.
    static func notched(_ rect: CGRect, radius: CGFloat) -> [CGRect] {
        let r = radius.rounded(.up)
        guard r > 0, rect.width > 2 * r, rect.height > 2 * r else { return [rect] }
        return [
            CGRect(x: rect.minX + r, y: rect.minY, width: rect.width - 2 * r, height: r),
            CGRect(x: rect.minX, y: rect.minY + r, width: rect.width, height: rect.height - 2 * r),
            CGRect(x: rect.minX + r, y: rect.maxY - r, width: rect.width - 2 * r, height: r),
        ]
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
