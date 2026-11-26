import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the panes under a zoom's or an unzoom's moving pane: they never show through it.
///
/// A zoom's pane grows over the panes that it covers, and an unzoom's pane closes over the panes that come back; those
/// panes show at their places under it for the whole move. A pane whose ground is clear (a docked Home in a glass or
/// art window) does not hide what is under it, so without a cut each of those panes showed inside the moving pane:
/// a browser page through Chief's chat (the 2:47 video, Nov 23). Each pane under the moving pane shows only outside
/// that pane's moving rect, as at rest, and the cut goes at the motion's end.
extension PaneCommitMotionTests {
    /// The part of `rect` (the screen's coordinates, inset by a point) in which `host`'s content shows at `part` of the
    /// moves on its clip's mask; nil: it shows nowhere in `rect`. A clip with no mask shows its whole rect.
    static func showing(_ host: PaneHostView, in rect: CGRect, at part: CGFloat, on screen: ScreenContentView) -> CGRect? {
        guard let clip = host.clipView.layer else { return nil }
        let inside = rect.insetBy(dx: 1, dy: 1).intersection(screen.convert(host.clipView.bounds, from: host.clipView))
        guard !inside.isNull, inside.width > 0.5, inside.height > 0.5 else { return nil }
        guard let mask = clip.mask else { return inside }
        let origin = screen.convert(host.clipView.bounds.origin, from: host.clipView)
        let base = CGPoint(x: origin.x + mask.frame.minX - clip.bounds.minX, y: origin.y + mask.frame.minY - clip.bounds.minY)
        let opaque = mask.backgroundColor.map { $0.alpha > 0 } ?? false
        let parts = opaque ? [mask.bounds] : (mask.sublayers ?? []).filter { !$0.isHidden }.map { Self.move(of: $0).rect(at: part) }
        for piece in parts {
            let cut = piece.offsetBy(dx: base.x, dy: base.y).intersection(inside)
            if !cut.isNull, cut.width > 0.5, cut.height > 0.5 { return cut }
        }
        return nil
    }

    /// Whether `host`'s content shows at `point` (the screen's coordinates) at the start of the moves on its clip's mask.
    static func shows(_ host: PaneHostView, at point: CGPoint, on screen: ScreenContentView) -> Bool {
        showing(host, in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4), at: 0, on: screen) != nil
    }

    /// The first frame after the zoom key: each pane that the zoom covers shows outside the pane that zooms, and in no
    /// point of that pane's rect at the start, the middle or the end of its move. The frame that ends the motion takes
    /// the cut away with the panes.
    @Test func aZoomsCoveredPanesNeverShowThroughThePaneThatZooms() throws {
        let zoom = try Self.zooming(frames: 1)
        defer { zoom.harness.window.closeAfterTest() }
        let screen = zoom.screen, hosts = Self.hosts(of: screen)
        let host = try #require(hosts["p4"], "the pane that zooms does not show"), layer = try #require(host.layer)
        let move = Self.move(of: layer)
        try #require(move.moves, "SETUP: the pane that zooms has no move")
        for pane in ["p1", "p2", "p3"] as [PaneID] {
            let other = try #require(hosts[pane], "\(pane) does not show under the pane that zooms")
            let place = try #require(zoom.grid.panes[pane])
            #expect(Self.shows(other, at: CGPoint(x: place.midX, y: place.midY), on: screen),
                    "\(pane) does not show at its place outside the pane that zooms, at the start of the move")
            for part in [0, 0.5, 1] as [CGFloat] {
                let through = Self.showing(other, in: move.rect(at: part), at: part, on: screen)
                #expect(through == nil, "at \(part) of the move \(pane) shows through the pane that zooms: \(String(describing: through))")
            }
        }
        _ = Self.toTheEnd(zoom.harness, screen)
        for pane in ["p1", "p2", "p3"] as [PaneID] {
            // The zoom retires the panes that it covers: read the hosts that showed under it.
            let other = try #require(hosts[pane])
            #expect(other.clipView.layer?.mask == nil, "after the motion's end \(pane)'s clip still has the zoom's cut")
        }
    }

    /// The first frame after the unzoom key: each pane that comes back shows at its place outside the pane that
    /// closes, and in no point of that pane's rect at the start, the middle or the end of its move. The frame that
    /// ends the motion takes the cut away: each pane shows whole.
    @Test func anUnzoomsReturningPanesNeverShowThroughThePaneThatCloses() throws {
        let unzoom = try Self.unzooming(frames: 1)
        let zoom = unzoom.zoom, screen = zoom.screen
        defer { zoom.harness.window.closeAfterTest() }
        let move = Self.move(of: try #require(unzoom.host.layer))
        try #require(move.moves, "SETUP: the pane that closes has no move")
        let hosts = Self.hosts(of: screen)
        for pane in ["p1", "p2", "p3"] as [PaneID] {
            let other = try #require(hosts[pane], "\(pane) does not come back")
            for part in [0, 0.5, 1] as [CGFloat] {
                let through = Self.showing(other, in: move.rect(at: part), at: part, on: screen)
                #expect(through == nil, "at \(part) of the move \(pane) shows through the pane that closes: \(String(describing: through))")
            }
            let place = try #require(zoom.grid.panes[pane])
            #expect(Self.showing(other, in: place, at: 1, on: screen) != nil, "\(pane) does not show at its place at the end of the move")
        }
        _ = Self.toTheEnd(zoom.harness, screen)
        for pane in ["p1", "p2", "p3"] as [PaneID] {
            let other = try #require(hosts[pane])
            #expect(other.clipView.layer?.mask == nil, "after the motion's end \(pane)'s clip still has the unzoom's cut")
        }
    }
}
