public import CoreGraphics

/// The frame of a floating pane's panel: the pane's fractions of its screen's pane area, as a rect in the
/// coordinates of the displays (the origin at the bottom left, y up). The fractions have their origin at the
/// area's top left, and a frame can leave the area.
public nonisolated enum FloatingPanelFrame {
    /// The height of the bar at a panel's top that a pointer moves the panel by.
    public static let barHeight: CGFloat = 14

    /// How much of the bar's width stays on a display.
    public static let reach: CGFloat = 40

    /// The frame of `fractions` of `area`, each edge on the pixel grid of `scale`.
    public static func frame(of fractions: CGRect, in area: CGRect, scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { scale > 0 ? (value * scale).rounded() / scale : value }
        let minX = snap(area.minX + fractions.minX * area.width), maxX = snap(area.minX + fractions.maxX * area.width)
        let top = snap(area.maxY - fractions.minY * area.height), bottom = snap(area.maxY - fractions.maxY * area.height)
        return CGRect(x: minX, y: bottom, width: max(0, maxX - minX), height: max(0, top - bottom))
    }

    /// The fractions of `area` that `frame` covers: the inverse of ``frame(of:in:scale:)``. The whole area when the
    /// area has no size.
    public static func fractions(of frame: CGRect, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (frame.minX - area.minX) / area.width, y: (area.maxY - frame.maxY) / area.height,
                      width: frame.width / area.width, height: frame.height / area.height)
    }

    /// `frame` where a pointer can reach its bar: as it is while the whole height of the bar and ``reach`` of its
    /// width are on one of `displays`; else moved the least that puts them on a display. The size stays. With no
    /// display the frame stays as it is.
    public static func reachable(_ frame: CGRect, displays: [CGRect]) -> CGRect {
        var best: (frame: CGRect, distance: CGFloat)?
        for display in displays where display.width > 0 && display.height > 0 {
            let moved = reachable(frame, on: display)
            let distance = abs(moved.minX - frame.minX) + abs(moved.minY - frame.minY)
            if distance == 0 { return frame }
            if best.map({ distance < $0.distance }) ?? true { best = (moved, distance) }
        }
        return best?.frame ?? frame
    }

    /// `frame` moved the least that puts its bar on `display`.
    private static func reachable(_ frame: CGRect, on display: CGRect) -> CGRect {
        let reach = min(reach, frame.width), bar = min(barHeight, frame.height)
        var origin = frame.origin
        // The x axis: `reach` of the bar's width on the display.
        origin.x = min(origin.x, display.maxX - reach)
        origin.x = max(origin.x, display.minX + reach - frame.width)
        // The y axis: the bar under the display's top edge and above its bottom edge. The top edge wins on a
        // display that is lower than the bar.
        origin.y = max(origin.y, display.minY + bar - frame.height)
        origin.y = min(origin.y, display.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }
}
