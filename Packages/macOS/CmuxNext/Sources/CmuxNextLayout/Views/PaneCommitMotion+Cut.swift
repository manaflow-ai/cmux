import AppKit
import CmuxNextDesign

/// What a move cuts from the panes that it keeps under the others.
///
/// A pane that a close took out, and a pane that a zoom covers, show under the panes of the layout to the motion's
/// end (``keepUnder(_:)``). A pane's tab strip has no ground of its own, and in a see-through window its content has
/// none. So without a cut a kept pane shows through the pane that goes over it: its tabs in that pane's tabs, its
/// content under them. A kept pane shows its rect without the rects of the panes over it, as they show: a mask on its
/// clip leaves that. The mask on the host's own layer (`PaneHostView.setStripClip`) stays as it is.
///
/// Each edge of the mask is the edge of one pane over the kept pane. The layer of the mask that has that edge gets a
/// copy of each move that is on that pane's layer now, one for each act, with that act's spring and start. So the
/// edge is on the pane's edge in each frame, also when a second act moves a pane that still moves from the first:
/// the pane's edge is then not at its place in the layout before the second act. No code runs in a frame: each act
/// makes the masks again from the moves that are on the panes' layers.
///
/// - Panes on one side of a kept pane (a close of a pane at an edge, a zoom): the mask is 4 bands around one hole,
///   the box of those panes. Two panes that move over one kept pane with a gap between them hide it in the gap too.
/// - Panes that start on 2 opposite sides of a kept pane (a close of a middle row of a column, or of a middle pane
///   with even split sizes): one box would have the whole pane in it, and the panes would grow over the window's
///   ground. The mask is the room between them: one layer that clips, from the edge of the panes on the one side, and
///   one layer in it, to the edge of the panes on the other.
/// - Panes on 2 sides that are not opposite, or on 3 sides: one box, which can hide more than the panes cover. No
///   single key gives that.
/// - A pane that is kept while it still moves (a second close of the pane that the first close made grow) takes its
///   clip and the mask with it. The mask's layer gets that move the other way, so the mask stays on the screen.
extension PaneCommitMotion {
    /// The name of the mask on a kept pane's clip.
    static let cutName = "pane.commit.cut"

    /// How far a layer of the mask goes from its edge: past each edge of a clip, and of a content that is larger than
    /// its clip.
    static let cutReach: CGFloat = 100_000

    /// An edge of a pane's rect.
    enum Edge: CaseIterable {
        case minX, maxX, minY, maxY

        func value(of rect: CGRect) -> CGFloat {
            switch self {
            case .minX: rect.minX
            case .maxX: rect.maxX
            case .minY: rect.minY
            case .maxY: rect.maxY
            }
        }
    }

    /// One act's move on a pane's layer: how far the layer's origin is from its place when that move starts, how much
    /// larger the layer is then, and one animation of the move, for its spring and its start.
    struct Ride {
        let act: Int
        let timing: CABasicAnimation
        let origin: CGPoint
        let size: CGSize

        /// How far `edge` of the layer is from its place when this move starts.
        func offset(of edge: Edge) -> CGPoint {
            switch edge {
            case .minX: CGPoint(x: origin.x, y: 0)
            case .maxX: CGPoint(x: origin.x + size.width, y: 0)
            case .minY: CGPoint(x: 0, y: origin.y)
            case .maxY: CGPoint(x: 0, y: origin.y + size.height)
            }
        }
    }

    /// A pane of a screen: its place, where its layer is when each move on it starts, and those moves.
    struct Mover {
        let host: PaneHostView
        let start: CGRect
        let end: CGRect
        let rides: [Ride]
    }

    /// The moves that are on `layer` now (``move(_:_:origin:size:)``), one for each act, in the acts' order.
    static func rides(on layer: CALayer) -> [Ride] {
        var found: [Int: (position: CABasicAnimation?, size: CABasicAnimation?)] = [:]
        for key in layer.animationKeys() ?? [] where key.hasPrefix("pane.commit.") {
            let words = key.dropFirst("pane.commit.".count).split(separator: ".", maxSplits: 1)
            guard words.count == 2, let act = Int(words[0]), let animation = layer.animation(forKey: key) as? CABasicAnimation else { continue }
            if words[1] == "position" { found[act, default: (nil, nil)].position = animation }
            if words[1] == "bounds.size" { found[act, default: (nil, nil)].size = animation }
        }
        let anchor = layer.anchorPoint
        var rides: [Ride] = []
        for act in found.keys.sorted() {
            guard let move = found[act], let timing = move.position ?? move.size else { continue }
            let point = (move.position?.fromValue as? NSValue)?.pointValue ?? .zero, size = (move.size?.fromValue as? NSValue)?.sizeValue ?? .zero
            rides.append(Ride(act: act, timing: timing, origin: CGPoint(x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height), size: size))
        }
        return rides
    }

    /// The 4 bands around `hole`, in the mask's coordinates: before it in x, after it in x, before it in y, after it
    /// in y. The order of ``Edge``'s cases: each band has that edge of the hole.
    static func bands(around hole: CGRect) -> [CGRect] {
        let far = cutReach, all = 2 * far
        let before = CGRect(x: hole.minX - far, y: -far, width: far, height: all), after = CGRect(x: hole.maxX, y: -far, width: far, height: all)
        let above = CGRect(x: -far, y: hole.minY - far, width: all, height: far), below = CGRect(x: -far, y: hole.maxY, width: all, height: far)
        return [before, after, above, below]
    }

    /// The pane of `panes` whose `edge` is the farthest at its place (`most`: the largest value); of panes with one
    /// place of that edge, the one whose edge starts the farthest.
    static func farthest(_ panes: [Mover], _ edge: Edge, most: Bool) -> Mover? {
        panes.max { a, b in
            let ends = (edge.value(of: a.end), edge.value(of: b.end)), starts = (edge.value(of: a.start), edge.value(of: b.start))
            let (x, y) = abs(ends.0 - ends.1) > 0.5 ? ends : starts
            return most ? x < y : x > y
        }
    }

    /// The 2 panes of `over` that have the room of a kept pane at `place` between them, when each pane of `over`
    /// starts on one of 2 opposite sides of `place`: the one before it whose edge is the last, and the one after it
    /// whose edge is the first. `vertical`: the sides are above and below. Nil: the panes start on one side, or one of
    /// them starts over `place` or beside it on the other axis.
    static func sides(of over: [Mover], around place: CGRect) -> (vertical: Bool, before: Mover, after: Mover)? {
        for vertical in [true, false] {
            let low: Edge = vertical ? .minY : .minX, high: Edge = vertical ? .maxY : .maxX
            let before = over.filter { high.value(of: $0.start) <= low.value(of: place) + 0.5 }
            let after = over.filter { low.value(of: $0.start) >= high.value(of: place) - 0.5 }
            guard before.count + after.count == over.count, let first = farthest(before, high, most: true),
                  let second = farthest(after, low, most: false) else { continue }
            return (vertical, first, second)
        }
        return nil
    }

    /// Makes the mask of each pane that the move keeps under the others, from the moves that are on the panes'
    /// layers now: an act's pass calls it after it added its moves. A kept pane shows its rect without the rects of
    /// the panes over it. Those are the panes that move and are over its place at the start or at the end of their
    /// moves, and the ones that were in an act before of this motion; a pane that left before the kept pane is not
    /// over it. A kept pane that no pane moves over gets no mask.
    func cutKept() {
        guard let screen = under.first.map({ $0.host })?.superview else { return }
        var all: [Mover] = []
        for case let host as PaneHostView in screen.subviews where !host.isHidden {
            guard let layer = host.layer else { continue }
            let rides = Self.rides(on: layer), end = layer.frame
            var start = end
            for ride in rides {
                start = CGRect(x: start.minX + ride.origin.x, y: start.minY + ride.origin.y, width: start.width + ride.size.width, height: start.height + ride.size.height)
            }
            all.append(Mover(host: host, start: start, end: end, rides: rides))
        }
        for (index, entry) in under.enumerated() {
            let host = entry.host, id = ObjectIdentifier(host)
            guard let clip = host.clipView.layer, host.superview === screen else { continue }
            let place = host.frame
            func isOver(_ rect: CGRect) -> Bool {
                let shared = rect.intersection(place)
                return !shared.isNull && shared.width > 0.5 && shared.height > 0.5
            }
            let before = under[..<index].map { $0.host }, had = covers[id] ?? []
            let over = all.filter { pane in
                guard pane.host !== host, !before.contains(where: { $0 === pane.host }) else { return false }
                return had.contains { $0 === pane.host } || (!pane.rides.isEmpty && (isOver(pane.start) || isOver(pane.end)))
            }
            guard !over.isEmpty else { continue }
            covers[id] = over.map(\.host)
            let mask = cut(clip, of: host), far = Self.cutReach
            func inClip(_ rect: CGRect) -> CGRect { host.clipView.convert(rect, from: screen) }
            if let sides = Self.sides(of: over, around: place) {
                let low: Edge = sides.vertical ? .maxY : .maxX, high: Edge = sides.vertical ? .minY : .minX
                let from = low.value(of: inClip(sides.before.end)), to = high.value(of: inClip(sides.after.end))
                // The outer layer clips: what it shows is from the first pane's edge on. Its own coordinates stay on
                // the screen when it moves (its origin moves as far), so the inner layer goes with the other pane only.
                let outer = CALayer(), inner = Self.part()
                outer.masksToBounds = true
                outer.frame = sides.vertical ? CGRect(x: -far, y: from, width: 2 * far, height: far) : CGRect(x: from, y: -far, width: far, height: 2 * far)
                outer.bounds.origin = outer.frame.origin
                inner.frame = sides.vertical ? CGRect(x: -far, y: to - far, width: 2 * far, height: far) : CGRect(x: to - far, y: -far, width: far, height: 2 * far)
                outer.addSublayer(inner)
                mask.addSublayer(outer)
                follow(outer, low, of: sides.before, paths: ["position", "bounds.origin"])
                follow(inner, high, of: sides.after)
                continue
            }
            // One hole: each edge of the box is the edge of the pane that is the farthest out on that side.
            let edges = Edge.allCases.compactMap { edge in Self.farthest(over, edge, most: edge == .maxX || edge == .maxY) }
            guard edges.count == 4 else { continue }
            let box = CGRect(x: edges[0].end.minX, y: edges[2].end.minY, width: edges[1].end.maxX - edges[0].end.minX, height: edges[3].end.maxY - edges[2].end.minY)
            for (side, frame) in Self.bands(around: inClip(box)).enumerated() {
                let band = Self.part()
                band.frame = frame
                mask.addSublayer(band)
                follow(band, Edge.allCases[side], of: edges[side])
            }
        }
    }

    /// A layer of a mask that shows the pane where it is.
    private static func part() -> CALayer {
        let part = CALayer()
        part.backgroundColor = CGColor(gray: 0, alpha: 1) // colour-allow: alpha-only mask coverage; this colour is never displayed
        return part
    }

    /// Gives `layer`, a layer of a mask, each move of `edge` of `pane`: the layer then goes with that edge as the
    /// pane shows it. `paths`: the layer's values that get the move.
    private func follow(_ layer: CALayer, _ edge: Edge, of pane: Mover, paths: [String] = ["position"]) {
        for ride in pane.rides {
            for path in paths { add(ride, to: layer, path, from: ride.offset(of: edge)) }
        }
    }

    /// Adds to `path` of `layer` a copy of the move `ride`, from `point` away to the layer's value. A move of this
    /// act starts with the pane's. A move of an act before has its start: the time that the render server gave the
    /// pane's animation, else the time of that act's pass.
    private func add(_ ride: Ride, to layer: CALayer, _ path: String, from point: CGPoint) {
        guard point != .zero, let move = ride.timing.copy() as? CABasicAnimation else { return }
        if ride.act != serial, move.beginTime == 0 {
            guard let time = began[ride.act] else { return }
            move.beginTime = layer.convertTime(time, from: nil)
        }
        move.keyPath = path
        move.fromValue = NSValue(point: point)
        move.toValue = NSValue(point: .zero)
        move.isAdditive = true
        let key = "pane.commit.\(serial).kept.\(ride.act).\(path)"
        layer.add(move, forKey: key)
        moved.append((layer: layer, key: key))
    }

    /// Puts a new mask on `clip`, the clip of `host`, in place of the one of an act before, and returns it: its
    /// coordinates are the clip's, and it has no layer yet. Each move that is still on the host's layer moves the
    /// clip too: the mask gets it the other way, with the same spring and the same start, so the mask stays where it
    /// is on the screen.
    private func cut(_ clip: CALayer, of host: PaneHostView) -> CALayer {
        assert(clip.mask == nil || clip.mask?.name == Self.cutName, "the clip of the pane \(host.pane) has a mask that is not the move's")
        let far = Self.cutReach
        let mask = CALayer()
        mask.name = Self.cutName
        mask.bounds = CGRect(x: -far, y: -far, width: 2 * far, height: 2 * far)
        mask.position = .zero
        clip.mask = mask
        for ride in host.layer.map({ Self.rides(on: $0) }) ?? [] {
            add(ride, to: mask, "position", from: CGPoint(x: -ride.origin.x, y: -ride.origin.y))
        }
        return mask
    }

    /// Takes the cut from `host`: it is a pane of the layout again, or the motion ends.
    func uncut(_ host: PaneHostView) {
        covers[ObjectIdentifier(host)] = nil
        guard let clip = host.clipView.layer, clip.mask?.name == Self.cutName else { return }
        clip.mask = nil
    }

    #if DEBUG
    /// The order that ``isUnderEachPane(_:unshown:)`` stands on: a pass that shows a change ends with each pane that
    /// left the layout under the others (``keepUnder(_:)``), or hidden. A pane that left the layout and shows in
    /// front of the others would cover a pane that no mask counts.
    func checkKept(on screen: ScreenContentView) {
        for case let host as PaneHostView in screen.subviews where host.isLeaving && !host.isHidden {
            assert(under.contains { $0.host === host }, "the pane \(host.pane) left the layout and shows in front after the pass that shows a change")
        }
    }
    #endif
}
