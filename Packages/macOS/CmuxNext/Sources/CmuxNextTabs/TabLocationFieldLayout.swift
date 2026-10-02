import CmuxNextDesign
import CoreGraphics

/// Where the strip's location field goes (plain math, testable with fixed
/// numbers): in the free space between the end of the tab run (the + button
/// when shown) and the trailing buttons, leading-aligned after a small gap,
/// as wide as the address needs up to that space. It never overlaps a tab or
/// a trailing button: with less than `minimumWidth` free it hides instead
/// of squeezing, and a long address is cut by `TabLocationText` (the rest
/// first, then the host at its head). A titlebar strip keeps `dragReserve`
/// of empty strip after the field.
enum TabLocationFieldLayout {
    /// Narrowest free space the field still shows in.
    static let minimumWidth: CGFloat = 120
    /// Empty strip a strip acting as the titlebar keeps after the field, so
    /// the window can still be dragged from it.
    static let dragReserve: CGFloat = 80

    /// The field's frame, or nil when it hides: no address to show, or less
    /// than `minimumWidth` between `runEnd + gap` and `limit - reserve`
    /// (`dragReserve` in a titlebar strip, else 0).
    static func frame(runEnd: CGFloat, limit: CGFloat, naturalWidth: CGFloat, gap: CGFloat,
                      reserve: CGFloat = 0, y: CGFloat, height: CGFloat) -> CGRect? {
        let start = runEnd + gap
        let available = limit - reserve - start
        guard naturalWidth > 0, available >= minimumWidth else { return nil }
        return CGRect(x: start, y: y, width: min(naturalWidth, available), height: height)
    }

    /// The tab run's far end for the field: the later of where it is drawn
    /// now and where it is going, so a tab growing in pushes the field away
    /// at once and a closing tab never slides under it.
    static func runEnd(current: CGFloat, target: CGFloat) -> CGFloat {
        max(current, target)
    }

    /// The default leading gap after the run.
    static var gap: CGFloat { Metrics.space2 }
}
