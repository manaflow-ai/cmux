import CmuxNextDesign
import CoreGraphics

/// Zoom and unzoom (Cmd-Shift-Enter). The pane that zooms is laid out live at its spring rect on
/// every frame, its tab strip and content included, as a live window resize is (decided
/// 2026-10-18: the content moves while the pane animates, and the tab bar is always visible).
/// It is the topmost layer until it lands (`ScreenContentView.rank`, DESIGN Z2 and Z4) and covers
/// the other panes: they stay still under it (`covered`) and are let go once it lands. An unzoom
/// finds them there. The others are dimmed while it moves and only then (a zoom at rest draws no
/// dim; before, they were covered and never faded): `dim` is how far the zoom is, on the pane's
/// spring and clock, and `PaneZoomDimView` draws it.
/// The `zoom` spring (`PaneMotionVariant.expandSpring`) moves it in and the shorter `unzoom` spring
/// (`restoreSpring`) moves it back; a second Cmd-Shift-Enter retargets it from its position, with its
/// velocity when that points to the new target (`SpringParameters.admitted`), on the spring of the new way.
struct PaneZoomMotion {
    /// The pane zooming in or back, until its spring lands.
    private(set) var pane: PaneID? { didSet { if pane == nil { dim = SpringValue(0) } } }
    private var token: MotionSpring = .zoom
    /// How dim the other panes are, 0 (as they are) to 1 (the whole of `Palette.zoomDim`): 1 is a zoom's
    /// target and 0 an unzoom's, set with the pane's target. It is 0 whenever no pane zooms.
    private(set) var dim = SpringValue(0)
    /// The panes a zoom left: under the zooming pane, unchanged, until it lands.
    private(set) var covered: Set<PaneID> = []

    /// A structural change: `pane` zooms in or back; nil, nothing does. Another change mid-flight
    /// keeps the zooming pane while it is still in the layout. `zooms`: it zooms in, so the others dim;
    /// else it goes back and they clear. A second key in mid-flight turns the dim from the value and speed
    /// it has; an unzoom from rest starts with the others as dim as the zoom left them when it covered them.
    mutating func begin(_ pane: PaneID?, in geometry: ScreenGeometry, variant: PaneMotionVariant = .standard, zooms: Bool = true) {
        guard let pane, geometry.panes[pane] != nil else {
            if let current = self.pane, geometry.panes[current] == nil { self.pane = nil }
            return
        }
        if self.pane == nil, !zooms { dim = SpringValue(1) }
        dim.target = zooms ? 1 : 0
        (self.pane, token) = (pane, zooms ? variant.expandSpring : variant.restoreSpring)
    }

    /// The spring parameters the zooming pane's frame runs on under `policy`; nil for every other pane.
    func parameters(for pane: PaneID, _ policy: MotionPolicy) -> SpringParameters? { pane == self.pane ? policy.spring(token) : nil }

    /// One step of the dim: the `dt` and the spring of the zooming pane's frame in the same step.
    mutating func advance(_ dt: Double, policy: MotionPolicy) {
        if pane != nil { dim.step(dt, parameters: policy.spring(token)) }
    }

    /// The zooming pane's frame this display frame: it stops owning the motion once it landed.
    mutating func track(_ pane: PaneID, _ frame: AnimatedFrame) {
        if pane == self.pane, frame.rect == frame.targetRect { self.pane = nil }
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
