import AppKit
import CmuxNextDesign

/// The panes under a moving pane show only outside it: a zoom's covered panes, an unzoom's panes that come back, and
/// a close's panes that its one growing neighbour takes the room of.
extension PaneCommitMotion {
    /// Each pane in `under` (under the pane of `change`) shows only outside that pane's rect until the motion's end:
    /// a mask on its clip (``PaneHoleMaskLayer``) whose hole goes with the pane on `token`. A moving pane whose ground is
    /// clear hides nothing under it, so the panes under it showed through it (a browser page through a docked Home in
    /// a glass window). A pane cut by an earlier act keeps its mask and its moves, and this move adds to them; a pane
    /// that is under no moving pane now loses its cut. The caller disables implicit actions.
    func cut(_ under: [PaneHostView], by change: Change, _ token: MotionSpring) {
        let ids = Set(under.map(ObjectIdentifier.init))
        for (id, host) in cuts where !ids.contains(id) { Self.uncut(host) }
        cuts = cuts.filter { ids.contains($0.key) }
        guard let screen = change.host.superview else { return }
        for host in under {
            guard let clip = host.clipView.layer else { continue }
            let mask = (clip.mask as? PaneHoleMaskLayer) ?? PaneHoleMaskLayer()
            // The mask's coordinates: the clip's, less its bounds origin.
            let shift = host.clipView.convert(CGPoint.zero, from: screen)
            func local(_ rect: CGRect) -> CGRect {
                rect.offsetBy(dx: shift.x - clip.bounds.minX, dy: shift.y - clip.bounds.minY)
            }
            let hole = local(change.new), old = local(change.old)
            mask.place(clip.bounds, hole: hole, from: old)
            if clip.mask !== mask { clip.mask = mask }
            cuts[ObjectIdentifier(host)] = host
            mask.moveHole(from: old) { part, origin, size in move(part, token, origin: origin, size: size) }
        }
    }

    /// Each pane under a moving pane shows whole again: the motion ends.
    func uncutAll() {
        for host in cuts.values { Self.uncut(host) }
        cuts = [:]
    }

    private static func uncut(_ host: PaneHostView) {
        guard let clip = host.clipView.layer, clip.mask is PaneHoleMaskLayer else { return }
        clip.mask = nil
    }
}
