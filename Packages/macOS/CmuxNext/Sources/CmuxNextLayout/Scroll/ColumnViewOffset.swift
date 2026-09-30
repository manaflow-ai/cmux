public import CoreGraphics
public import CmuxNextDesign

/// niri's view-offset rules (src/layout/scrolling.rs at 1f03391), in cmux's
/// content-space offsets (the x of the viewport's leading edge) and clamped
/// to the strip: cmux never scrolls past the first or last column.
public nonisolated enum ColumnViewOffset {
    /// niri `compute_new_view_offset`: leave the view if `rect` is fully
    /// visible (with its padding); otherwise align the edge that needs less
    /// motion. A rect as wide as the view is left-aligned.
    public static func fit(_ rect: CGRect, current: CGFloat, strip: ColumnStrip) -> CGFloat {
        let width = strip.viewportWidth
        if width <= rect.width { return strip.clamp(rect.minX) }
        let pad = strip.padding(for: rect.width)
        let left = rect.minX - pad
        let right = rect.maxX + pad
        if current <= left + 0.5 && right <= current + width + 0.5 { return strip.clamp(current) }
        let toLeft = abs(current - left)
        let toRight = abs(current + width - right)
        return strip.clamp(toLeft <= toRight ? left : right - width)
    }

    /// niri `compute_new_view_offset_centered`: the column in the middle; a
    /// column as wide as the view is left-aligned like `fit`.
    public static func center(_ rect: CGRect, current: CGFloat, strip: ColumnStrip) -> CGFloat {
        if strip.viewportWidth <= rect.width { return fit(rect, current: current, strip: strip) }
        return strip.clamp(rect.midX - strip.viewportWidth / 2)
    }

    /// niri `compute_new_view_offset_for_column`, plus the focused pane of a
    /// column wider than the view: if that pane is visible now, nothing
    /// moves; else the column's left edge if that shows the pane; else the
    /// least scroll that shows the pane.
    public static func target(
        column index: Int,
        pane: PaneID?,
        current: CGFloat,
        mode: CenterFocusedColumn,
        previous: Int?,
        strip: ColumnStrip
    ) -> CGFloat {
        let column = strip.columns[index]
        if strip.isWide(column.frame), let pane, let paneFrame = column.paneFrames[pane] {
            // Inside a wide column the pane's own edges count, not its padding.
            if shows(paneFrame, current, strip) { return strip.clamp(current) }
            let leftAligned = strip.clamp(column.frame.minX)
            if shows(paneFrame, leftAligned, strip) { return leftAligned }
            return fit(paneFrame, current: current, strip: strip)
        }
        switch mode {
        case .never:
            return fit(column.frame, current: current, strip: strip)
        case .always:
            return center(column.frame, current: current, strip: strip)
        case .onOverflow:
            guard let previous, previous != index, strip.columns.indices.contains(previous) else {
                return fit(column.frame, current: current, strip: strip)
            }
            // niri: the source is always the target's neighbor on the side focus came from.
            let source = previous > index ? min(index + 1, strip.columns.count - 1) : max(index - 1, 0)
            let a = strip.columns[source].frame
            let b = column.frame
            let span = max(a.maxX, b.maxX) - min(a.minX, b.minX) + strip.gap * 2
            return span <= strip.viewportWidth + 0.5
                ? fit(b, current: current, strip: strip)
                : center(b, current: current, strip: strip)
        }
    }

    /// The rect lies inside the viewport, or covers all of it.
    private static func shows(_ rect: CGRect, _ offset: CGFloat, _ strip: ColumnStrip) -> Bool {
        let end = offset + strip.viewportWidth
        let inside = rect.minX >= offset - 0.5 && rect.maxX <= end + 0.5
        let covers = rect.minX <= offset + 0.5 && rect.maxX >= end - 0.5
        return inside || covers
    }

    /// A resting point of a trackpad gesture and the column it belongs to.
    public struct Snap: Hashable, Sendable {
        public var offset: CGFloat
        public var column: Int
    }

    /// niri `view_offset_gesture_end` snapping points: each column's left and
    /// right alignment (with padding); column centers when centering is
    /// always on; under `on-overflow`, an edge whose neighbor cannot share the
    /// screen snaps to the center instead. Clamped to the strip, ascending.
    public static func snaps(strip: ColumnStrip, mode: CenterFocusedColumn) -> [Snap] {
        guard !strip.columns.isEmpty else { return [] }
        let width = strip.viewportWidth
        var result: [Snap] = []
        for (index, column) in strip.columns.enumerated() {
            let frame = column.frame
            let centered = strip.clamp(width <= frame.width ? frame.minX : frame.midX - width / 2)
            if mode == .always {
                result.append(Snap(offset: centered, column: index))
                continue
            }
            let pad = strip.padding(for: frame.width)
            func overflows(_ neighbor: Int) -> Bool {
                guard mode == .onOverflow, strip.columns.indices.contains(neighbor) else { return false }
                return strip.columns[neighbor].frame.width + strip.gap * 3 + frame.width > width
            }
            let left = overflows(index + 1) ? centered : strip.clamp(frame.minX - pad)
            let right = overflows(index - 1) ? centered : strip.clamp(frame.maxX + pad - width)
            result.append(Snap(offset: left, column: index))
            result.append(Snap(offset: right, column: index))
        }
        result.sort { ($0.offset, $0.column) < ($1.offset, $1.column) }
        var unique: [Snap] = []
        for snap in result where unique.last.map({ abs($0.offset - snap.offset) > 0.5 }) ?? true {
            unique.append(snap)
        }
        return unique
    }

    /// niri gesture end: after snapping, focus the column farthest in the
    /// gesture's direction that is fully visible. cmux keeps the focused
    /// column instead when it is still visible, so a peek does not move the
    /// keyboard. Returns nil when focus stays.
    public static func focusAfterScroll(
        focused: Int?,
        snapColumn: Int,
        target: CGFloat,
        forward: Bool,
        strip: ColumnStrip
    ) -> Int? {
        if let focused, strip.columns.indices.contains(focused), strip.isColumnVisible(focused, at: target) { return nil }
        let visible = strip.columns.indices.filter { strip.isColumnVisible($0, at: target) }
        guard var index = visible.min(by: { abs($0 - snapColumn) < abs($1 - snapColumn) }) else { return nil }
        if forward {
            while index + 1 < strip.columns.count, strip.isColumnVisible(index + 1, at: target) { index += 1 }
        } else {
            while index > 0, strip.isColumnVisible(index - 1, at: target) { index -= 1 }
        }
        return index == focused ? nil : index
    }
}
