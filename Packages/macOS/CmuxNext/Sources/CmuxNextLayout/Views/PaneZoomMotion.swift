import CmuxNextDesign
import CoreGraphics

/// Zoom and unzoom (Leo 2026-10-13: the expanding pane owns the motion, the opposite corner exits
/// first and fastest, no pane sits around once the zoom is asked for, and no terminal relayouts
/// per frame). The pane that zooms keeps one host size, the full screen's, for the whole move: a
/// zoom resizes its terminal once, up front, and its spring rect reveals it; an unzoom clips it to
/// the shrinking rect and resizes it once it lands. The panes a zoom leaves fade out under it on
/// `exit` springs, the farthest from it fastest, and are let go as each one settles; an unzoom
/// brings them back from the opacity (and velocity) they had.
struct PaneZoomMotion {
    struct Leaving {
        var alpha: SpringValue
        let center: CGPoint
        var parameters: SpringParameters
    }

    /// The pane zooming in or back, until its spring lands.
    private(set) var pane: PaneID?
    private var token: MotionSpring = .move
    /// Its host's size for the whole move.
    private var size: CGSize = .zero
    /// Its center when the zoom started: the leaving panes' distances are from there.
    private var origin: CGPoint = .zero
    private(set) var leaving: [PaneID: Leaving] = [:]

    /// A structural change: `pane` zooms in (`zooming`) or back, from `frames[pane]`; nil, nothing does.
    mutating func begin(_ pane: PaneID?, zooming: Bool, frames: [PaneID: AnimatedFrame], to geometry: ScreenGeometry,
                        variant: PaneMotionVariant = .standard) {
        guard let pane, let frame = frames[pane], let size = (zooming ? geometry.panes[pane] : frame.targetRect)?.size else {
            // Another change mid-flight: the zooming pane keeps its size and reveal until it lands.
            if let current = self.pane, geometry.panes[current] == nil { self.pane = nil }
            return
        }
        (self.pane, token, self.size) = (pane, zooming ? variant.expandSpring : variant.closeSpring, size)
        origin = CGPoint(x: frame.rect.midX, y: frame.rect.midY)
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

    /// `pane` left the layout with the zoom: it fades out from `frame`'s opacity, the farthest of
    /// the leaving panes from the zoomed one fastest.
    mutating func leave(_ pane: PaneID, _ frame: AnimatedFrame) {
        var alpha = frame.alpha
        alpha.target = 0
        leaving[pane] = Leaving(alpha: alpha, center: CGPoint(x: frame.rect.midX, y: frame.rect.midY), parameters: Motion.spring(.exit))
        let far = leaving.values.map { distance($0.center) }.max() ?? 0
        let ranked = leaving.mapValues { Motion.exit(nearness: far > 0 ? 1 - distance($0.center) / far : 0) }
        for (id, parameters) in ranked { leaving[id]?.parameters = parameters }
    }

    /// `pane` is in the layout again. An unzoom (`revealing`) fades it in from where its fade out
    /// left it (0 once it was let go); otherwise it shows as is. Nil: not faded.
    mutating func returning(_ pane: PaneID, revealing: Bool) -> SpringValue? {
        let back = leaving.removeValue(forKey: pane)?.alpha
        return revealing ? back ?? SpringValue(0) : nil
    }

    /// Steps the fades. Returns true while one still moves.
    mutating func advance(_ dt: Double) -> Bool {
        var moving = false
        for (id, var entry) in leaving {
            if entry.alpha.advance(dt, parameters: entry.parameters, epsilon: 0.004) { moving = true }
            leaving[id] = entry
        }
        return moving
    }

    var isMoving: Bool { leaving.values.contains { $0.alpha.value != $0.alpha.target || $0.alpha.velocity != 0 } }

    var opacities: [(PaneID, CGFloat)] { leaving.map { ($0.key, $0.value.alpha.value) } }

    /// The leaving panes whose fade ended (every one with `all`), no longer tracked.
    mutating func settled(all: Bool = false) -> [PaneID] {
        let done = leaving.filter { all || ($0.value.alpha.value == $0.value.alpha.target && $0.value.alpha.velocity == 0) }.map(\.key)
        for id in done { leaving[id] = nil }
        return done
    }

    private func distance(_ point: CGPoint) -> CGFloat { hypot(point.x - origin.x, point.y - origin.y) }
}
