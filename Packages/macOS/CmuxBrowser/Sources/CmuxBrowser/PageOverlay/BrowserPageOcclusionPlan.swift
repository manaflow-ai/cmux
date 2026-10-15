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
/// A rounded overlay (a card with corner radius r) gets a notched hole: non-
/// overlapping rects (one-point slabs that follow the corner arcs at each edge
/// and the full-width middle), so the page shows outside the card's rounded
/// corners instead of a square of cmux's background behind it (design spec §0.9).
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
        let pieces = kept.flatMap { rect -> [CGRect] in
            guard let index = shown.indices.first(where: { !used.contains($0) && shown[$0].rect == rect }) else { return [] }
            used.insert(index)
            return Self.notched(rect, radius: shown[index].cornerRadius)
                .map { $0.intersection(contentBounds) }
                .filter { !$0.isNull && !$0.isEmpty }
        }
        // Overlapping cards (a find bar over a permission strip in a short
        // pane) would cut overlapping holes, and the fork's even-odd mask shows
        // the page again where two holes overlap. The holes are their union as
        // disjoint rects.
        return Self.disjointUnion(pieces)
    }

    /// The union of `rects` as non-overlapping rects: horizontal bands between
    /// every distinct edge, each band's covered x-ranges merged, and bands with
    /// the same ranges joined vertically.
    static func disjointUnion(_ rects: [CGRect]) -> [CGRect] {
        let rects = rects.filter { !$0.isNull && !$0.isEmpty }
        guard rects.count > 1 else { return rects }
        let edges = Set(rects.flatMap { [$0.minY, $0.maxY] }).sorted()
        var result: [CGRect] = []
        var open: [ClosedRange<CGFloat>: CGRect] = [:]
        for (top, bottom) in zip(edges, edges.dropFirst()) {
            let spans = rects
                .filter { $0.minY < bottom && $0.maxY > top }
                .map { $0.minX...$0.maxX }
                .sorted { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<CGFloat>] = []
            for span in spans {
                if let last = merged.last, span.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
            var next: [ClosedRange<CGFloat>: CGRect] = [:]
            for span in merged {
                if let running = open.removeValue(forKey: span), running.maxY == top {
                    next[span] = CGRect(x: running.minX, y: running.minY, width: running.width, height: bottom - running.minY)
                } else {
                    next[span] = CGRect(x: span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: bottom - top)
                }
            }
            result.append(contentsOf: open.values)
            open = next
        }
        result.append(contentsOf: open.values)
        return result.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// `rect` as three non-overlapping rects that leave its r x r corners
    /// out; `rect` itself for no radius or a rect too small to notch.
    static func notched(_ rect: CGRect, radius: CGFloat) -> [CGRect] {
        let r = radius.rounded(.up)
        guard r > 0, rect.width > 2 * r, rect.height > 2 * r else { return [rect] }
        // One-point slabs follow the arc (at most 12 per corner), so the hole
        // reads as a rounded corner rather than a square step at 2x.
        let steps = Int(min(r, 12))
        let slab = r / CGFloat(steps)
        var rects: [CGRect] = []
        for step in 0..<steps {
            // Distance from the corner circle's center at the slab's middle row.
            let fromCenter = r - (CGFloat(step) + 0.5) * slab
            let inset = (r - (r * r - fromCenter * fromCenter).squareRoot()).rounded()
            let width = rect.width - 2 * inset
            let offset = CGFloat(step) * slab
            rects.append(CGRect(x: rect.minX + inset, y: rect.minY + offset, width: width, height: slab))
            rects.append(CGRect(x: rect.minX + inset, y: rect.maxY - offset - slab, width: width, height: slab))
        }
        rects.append(CGRect(x: rect.minX, y: rect.minY + r, width: rect.width, height: rect.height - 2 * r))
        return rects
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
