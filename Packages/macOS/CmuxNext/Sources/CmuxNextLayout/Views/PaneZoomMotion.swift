import CmuxNextDesign
import CoreGraphics

/// Zoom and unzoom (Cmd-Shift-Enter). The pane that zooms keeps one host size, the full screen's,
/// for the whole move: a zoom resizes its terminal once, up front, and its spring rect reveals it;
/// an unzoom clips it to the shrinking rect and resizes it once it lands. It is the topmost layer
/// until it lands (`ScreenContentView.rank`, DESIGN Z2 and Z4) and simply covers the other panes
/// (Lawrence 2026-10-18: "we dont fade away other stuff, but rather just cover it up"): they stay
/// opaque and still under it (`covered`) and are let go once it lands. An unzoom finds them there.
/// One spring (`zoom`, `PaneMotionVariant.expandSpring`) moves it both ways; a second Cmd-Shift-Enter retargets it with its velocity.
struct PaneZoomMotion {
    /// The pane zooming in or back, until its spring lands.
    private(set) var pane: PaneID?
    private var token: MotionSpring = .zoom
    /// Its host's size for the whole move.
    private var size: CGSize = .zero
    /// The panes a zoom left: under the zooming pane, unchanged, until it lands.
    private(set) var covered: Set<PaneID> = []

    /// A structural change: `pane` zooms in (`zooming`) or back, from `frames[pane]`; nil, nothing does.
    mutating func begin(_ pane: PaneID?, zooming: Bool, frames: [PaneID: AnimatedFrame], to geometry: ScreenGeometry,
                        variant: PaneMotionVariant = .standard) {
        guard let pane, let frame = frames[pane], let size = (zooming ? geometry.panes[pane] : frame.targetRect)?.size else {
            // Another change mid-flight: the zooming pane keeps its size and reveal until it lands.
            if let current = self.pane, geometry.panes[current] == nil { self.pane = nil }
            return
        }
        (self.pane, token, self.size) = (pane, variant.expandSpring, size)
    }

    /// The spring `pane`'s frame runs on.
    func spring(for pane: PaneID, fallback: MotionSpring = .move) -> MotionSpring { pane == self.pane ? token : fallback }

    /// The zooming pane's host frame: full size, with the spring rect's leading edge and its bottom
    /// (where a terminal's prompt is); the rect clips it. Nil for other panes and once it lands.
    mutating func presentation(of pane: PaneID, _ frame: AnimatedFrame) -> CGRect? {
        guard pane == self.pane else { return nil }
        guard frame.rect != frame.targetRect else {
            self.pane = nil
            return nil
        }
        return CGRect(x: frame.rect.minX, y: frame.rect.maxY - size.height, width: size.width, height: size.height)
    }

    /// `pane` left the layout with the zoom: it stays where it is, under the zooming pane.
    mutating func leave(_ pane: PaneID) { covered.insert(pane) }

    /// `pane` is in the layout again (an unzoom, or a close while zoomed): it was never changed.
    mutating func returning(_ pane: PaneID) { covered.remove(pane) }

    /// The covered panes to let go: all of them once the zooming pane landed (every one with `all`).
    mutating func settled(all: Bool = false) -> [PaneID] {
        guard all || pane == nil else { return [] }
        defer { covered.removeAll() }
        return Array(covered)
    }
}
