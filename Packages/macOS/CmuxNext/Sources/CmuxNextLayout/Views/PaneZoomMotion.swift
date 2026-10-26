import CmuxNextDesign
import CoreGraphics

/// Zoom and unzoom (Cmd-Shift-Enter). The pane that zooms is laid out live at its spring rect on
/// every frame, its tab strip and content included, as a live window resize is (Lawrence
/// 2026-10-18: "content must move while it animates"; the tab bar "needs to always be visible").
/// It is the topmost layer until it lands (`ScreenContentView.rank`, DESIGN Z2 and Z4) and simply
/// covers the other panes ("we dont fade away other stuff, but rather just cover it up"): they stay
/// opaque and still under it (`covered`) and are let go once it lands. An unzoom finds them there.
/// One spring (`zoom`, `PaneMotionVariant.expandSpring`) moves it both ways; a second
/// Cmd-Shift-Enter retargets it with its velocity.
///
/// With `motion.renderServer` on, Core Animation runs that spring (``rendersOnServer``,
/// `ScreenContentView.springZoomOnRenderServer()`): the pane's frame is at rest from the key's turn,
/// so it owns the motion, and stays above the docks, until the render server says it landed
/// (``landedOnRenderServer()``), not until its frame reaches rest.
struct PaneZoomMotion {
    /// The pane zooming in or back, until its spring lands.
    private(set) var pane: PaneID?
    private var token: MotionSpring = .zoom
    /// The panes a zoom left: under the zooming pane, unchanged, until it lands.
    private(set) var covered: Set<PaneID> = []
    /// While the render server runs the zooming pane's spring: the screen rect it springs across, from where
    /// it showed to its rest. Its frame is at rest already, so what stacks behind it reads this until it
    /// lands (`ScreenContentView.coverFrame(_:)`).
    private(set) var renderSweep: CGRect?
    /// The zooming pane's spring runs on the render server: it owns the motion until that spring lands.
    var rendersOnServer: Bool { renderSweep != nil }

    /// A structural change: `pane` zooms in or back; nil, nothing does. Another change mid-flight
    /// keeps the zooming pane while it is still in the layout.
    mutating func begin(_ pane: PaneID?, in geometry: ScreenGeometry, variant: PaneMotionVariant = .standard) {
        guard let pane, geometry.panes[pane] != nil else {
            if let current = self.pane, geometry.panes[current] == nil { self.pane = nil }
            return
        }
        (self.pane, token) = (pane, variant.expandSpring)
    }

    /// The spring `pane`'s frame runs on.
    func spring(for pane: PaneID, fallback: MotionSpring = .move) -> MotionSpring { pane == self.pane ? token : fallback }

    /// The zooming pane's frame this display frame: it stops owning the motion once it landed (on the
    /// render server, its frame is at rest from the start: ``landedOnRenderServer()`` ends it).
    mutating func track(_ pane: PaneID, _ frame: AnimatedFrame) {
        if pane == self.pane, !rendersOnServer, frame.rect == frame.targetRect { self.pane = nil }
    }

    /// The render server took the zooming pane's spring from `from` to `to` (screen rects).
    mutating func handToRenderServer(from: CGRect, to: CGRect) { renderSweep = pane == nil ? nil : from.union(to) }

    /// A structural change took the render server's springs back to the CPU frames
    /// (`ScreenContentView.takeRenderSpringsBack()`): the zooming pane's frame shows where it is again,
    /// and lands as on the CPU unless the render server takes it once more.
    mutating func takeBackFromRenderServer() { renderSweep = nil }

    /// The render server's springs landed. Returns true when they carried the zoom: the pane no longer owns
    /// the motion, and the covered panes may be let go (``settled(all:)``).
    mutating func landedOnRenderServer() -> Bool {
        guard rendersOnServer else { return false }
        (renderSweep, pane) = (nil, nil)
        return true
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
