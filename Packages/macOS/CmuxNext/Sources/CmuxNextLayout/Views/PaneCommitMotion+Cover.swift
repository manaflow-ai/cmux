import AppKit
import CmuxNextDesign

/// The panes under several panes that move with no ground.
///
/// Under ONE pane that moves (a zoom, an unzoom, a close in which one pane takes the room) each pane shows only
/// outside that pane: a mask with a hole on its clip, in each kind of window (`PaneCommitMotion+Under`). No one hole
/// goes with several panes, so only an act that moves more than one pane (a close in which several panes take the
/// room) gets this file's way.
///
/// A pane that moves has the window's ground under its content where the window gives one: an opaque window's colour,
/// or a copy of one still picture (`PaneCommitMotion+Sheet`). It then covers what is under it. A glass window, a
/// blurred or see-through picture and a window with no picture give no ground, and a pane's tab row and the room
/// around its content paint nothing: a pane under the ones that move would show through them. So there each pane
/// under the panes that move shows only past one edge of each of them, in each frame of the move.
///
/// How. A pane's host clips what is in it to its own layer. The host's layer becomes a window that goes with the
/// edge of the pane over it: its place and the origin of its own coordinates move by the same amount, on the act's
/// spring, so the window slides and the content in it stays where it is. The window is as large as the pane's far
/// edge needs at the end of the move at which the pane shows most; that size is constant in the move. No mask, no
/// picture and no layer more: 3 animations for each such pane (the place, the origin, the size), 2 where the window
/// has the pane's own size. A window that gives a pane a ground gets none of this, and no pane under it does.
///
/// The side. A window on one edge shows nothing of a pane inside the pane over it, on each side. For a pane in the
/// row or the column of the pane that moves it takes nothing more. A pane in another row and another column loses a
/// corner in some frames: the part that is past that edge and beside the other one. The side is the one that takes
/// the least of the pane, by reads of the way (``coverSide(of:under:to:)``).
///
/// The window stays at its end until the motion's end takes it away (``finish()``): a pane that a close took out does
/// not come back in a frame between the spring's end and the frame that hides it. A later act in the move that moves
/// one pane gives no window; a window of the act before stays while its pane is kept under. When that one pane has
/// no ground, the act ends the move that a pane under it still has of an act before: that pane is at its place in
/// one frame, and the mask on its clip is for a pane at its place.
extension PaneCommitMotion {
    /// One edge of a pane that moves. A pane under it shows only past that edge: `minX` at a smaller x, and so on.
    enum CoverSide: CaseIterable {
        case maxX, minX, maxY, minY

        /// What a window on this edge of `rect` shows of a pane at `frame`.
        func shows(of frame: CGRect, past rect: CGRect) -> CGRect {
            let past: CGRect
            switch self {
            case .maxX: past = CGRect(x: rect.maxX, y: frame.minY, width: max(0, frame.maxX - rect.maxX), height: frame.height)
            case .minX: past = CGRect(x: frame.minX, y: frame.minY, width: max(0, rect.minX - frame.minX), height: frame.height)
            case .maxY: past = CGRect(x: frame.minX, y: rect.maxY, width: frame.width, height: max(0, frame.maxY - rect.maxY))
            case .minY: past = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, rect.minY - frame.minY))
            }
            let shown = frame.intersection(past)
            return shown.isNull ? .zero : shown
        }

        /// This edge of `rect`, on its axis.
        func edge(of rect: CGRect) -> CGFloat {
            switch self {
            case .maxX: rect.maxX
            case .minX: rect.minX
            case .maxY: rect.maxY
            case .minY: rect.minY
            }
        }
    }

    /// The reads of the way by which ``coverSide(of:under:to:)`` compares the sides: the start, the end and 7 between.
    static let coverReads = 8

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// How much of a pane at `frame` a window on `side` takes that the pane over it does not cover, when that pane
    /// is at `rect`: the area of the pane outside `rect`, less the area that the window shows.
    static func lost(of frame: CGRect, past side: CoverSide, of rect: CGRect) -> CGFloat {
        max(0, area(frame) - area(frame.intersection(rect)) - area(side.shows(of: frame, past: rect)))
    }

    /// The side of the pane that moves from `old` to `new` past which a pane at `frame` shows in that move: the one
    /// that takes the least of the pane, summed over the reads of the way. A side that takes nothing is the choice
    /// at once, in the order of the cases.
    static func coverSide(of frame: CGRect, under old: CGRect, to new: CGRect) -> CoverSide {
        var best = CoverSide.maxX, least = CGFloat.infinity
        for side in CoverSide.allCases {
            var sum: CGFloat = 0
            for read in 0...coverReads {
                let way = CGFloat(read) / CGFloat(coverReads)
                let rect = CGRect(x: old.minX + (new.minX - old.minX) * way, y: old.minY + (new.minY - old.minY) * way,
                                  width: old.width + (new.width - old.width) * way, height: old.height + (new.height - old.height) * way)
                sum += lost(of: frame, past: side, of: rect)
            }
            // A side takes the place of one before it only when it takes less by more than a rounding: a move and
            // the move back give one side.
            if sum < least - 0.5 { (best, least) = (side, sum) }
            if sum < 1 { break }
        }
        return best
    }

    /// The bounds of a pane's window on one axis, at the start and at the end of a move. `low`: the lower bound goes
    /// with an edge; `high`: the higher one does. Nil: that bound is the pane's own.
    private struct Span {
        var low: (start: CGFloat, end: CGFloat)?
        var high: (start: CGFloat, end: CGFloat)?

        /// The lower bound goes with `edge` too: at each end of the move it is the larger of its edges.
        mutating func raise(to edge: (start: CGFloat, end: CGFloat)) {
            low = (start: max(low?.start ?? edge.start, edge.start), end: max(low?.end ?? edge.end, edge.end))
        }

        /// The higher bound goes with `edge` too: at each end of the move it is the smaller of its edges.
        mutating func lower(to edge: (start: CGFloat, end: CGFloat)) {
            high = (start: min(high?.start ?? edge.start, edge.start), end: min(high?.end ?? edge.end, edge.end))
        }

        /// The window on this axis for a pane from `near` to `far`: its lower bound and its length at each end. A
        /// bound that goes with an edge is at that edge; the other bound is as far from it as the pane's own far
        /// side is at the end of the move at which the edge is nearest to the pane's start.
        func window(near: CGFloat, far: CGFloat) -> (start: CGFloat, startLength: CGFloat, end: CGFloat, endLength: CGFloat) {
            switch (low, high) {
            case (nil, nil):
                return (near, far - near, near, far - near)
            case (let low?, nil):
                let length = max(0, far - min(low.start, low.end))
                return (low.start, length, low.end, length)
            case (nil, let high?):
                let length = max(0, max(high.start, high.end) - near)
                return (high.start - length, length, high.end - length, length)
            case (let low?, let high?):
                return (low.start, max(0, high.start - low.start), low.end, max(0, high.end - low.end))
            }
        }
    }

    /// Each pane of `hosts` (the panes under the panes of `changes`) shows only past one edge of each pane of `changes`
    /// that has no ground and goes over it, from this pass to the motion's end, when the act moves more than one
    /// pane. A pane over which no such pane goes gets nothing. A pane with
    /// a window from an act before goes on from that window's end: the 2 moves add up, as the moves of the panes over
    /// it do (a close, and a second close in its move). When this act's window starts at another place, the pane gets
    /// this act's window alone.
    ///
    /// An act that moves ONE pane makes no window here: its way is the mask of ``cut(_:by:_:)``. In a move, when that
    /// pane has no ground, this pass ends the move that a pane of `hosts` still has of an act before
    /// (``endOwnMove(of:)``): the mask is made for a pane at rest. In a first act it reads no pane.
    ///
    /// A window of an act before goes when this act moves its pane, or when a change took its pane back into the
    /// layout (a close, taken back), unless this act's window goes on from it. Else it stays: the move still keeps
    /// the pane under.
    func cover(_ hosts: [PaneHostView], under changes: [Change], _ token: MotionSpring) {
        let several = changes.count > 1
        if !several, let change = changes.first { carryMoves(of: change, toTheMasksOf: hosts) }
        let bare = changes.filter { change in !sheets.contains { $0.host === change.host } }
        var stale = covers.filter { entry in
            let had = entry.value
            return changes.contains { $0.host === had.host } || !had.host.isLeaving
        }
        defer {
            for (id, had) in stale {
                uncover(had.host, of: had.acts)
                covers[id] = nil
            }
        }
        for host in bare.isEmpty || !(several || inFlight) ? [] : hosts where !host.isHidden && !changes.contains(where: { $0.host === host }) {
            guard let layer = host.layer else { continue }
            if inFlight { endOwnMove(of: host) }
            guard several else { continue } // one pane that moves: no window
            let frame = layer.frame
            var across = Span(), down = Span()
            for change in bare where Self.area(frame.intersection(change.old.union(change.new))) >= 1 {
                let side = Self.coverSide(of: frame, under: change.old, to: change.new)
                let edge = (start: side.edge(of: change.old), end: side.edge(of: change.new))
                switch side {
                case .maxX: across.raise(to: edge)
                case .minX: across.lower(to: edge)
                case .maxY: down.raise(to: edge)
                case .minY: down.lower(to: edge)
                }
            }
            let x = across.window(near: frame.minX, far: frame.maxX), y = down.window(near: frame.minY, far: frame.maxY)
            let start = CGRect(x: x.start, y: y.start, width: x.startLength, height: y.startLength)
            let end = CGRect(x: x.end, y: y.end, width: x.endLength, height: y.endLength)
            // No pane of this act goes over it: a window of an act before stays, or goes with the stale ones.
            guard start != frame || end != frame else { continue }
            let id = ObjectIdentifier(host)
            var base = frame, acts = [serial]
            if let had = covers[id] {
                let far = [had.window.minX - start.minX, had.window.minY - start.minY, had.window.width - start.width, had.window.height - start.height]
                if had.frame == frame, far.allSatisfy({ abs($0) < 0.5 }) {
                    // The window of the acts before stays on the layer, at its end or on its way there: this one
                    // starts where that one ends, and adds to it.
                    (base, acts) = (had.window, had.acts + acts)
                } else {
                    // Another pane goes over it now, or its own place changed: the window of this act alone.
                    uncover(host, of: had.acts)
                }
            }
            window(layer, token, from: start, to: end, over: base)
            covers[id] = (host: host, frame: frame, window: end, acts: acts)
            stale[id] = nil
        }
    }

    /// The mark in the key of a copy of a pane's move, on a part of a mask: the key of a copy is the key of the move,
    /// then this mark, then the number of the pane that it is a copy for. No other key of this motion has the mark.
    private static let copyMark = ".copy."

    /// The one pane that moves (`change`) can still have the moves of acts before on its layer: a second key in a
    /// move. The hole of a mask that ``cut(_:by:_:)`` made in this act goes with this act's move alone, so it was
    /// ahead of the pane by what is left of those moves, and a pane of `hosts` (the panes under it) was cut in a band
    /// outside the pane over it. Each part of such a mask gets a copy of each of those moves, with the part's own
    /// distance. A copy is the move's own animation with other values: its spring, its duration and its start time
    /// are the move's, and none of them is from this act's clock. So the hole is the pane's rect at each time.
    /// A pane that moves from rest has no such move: it gets no animation and no layer here. The pane's own window
    /// of an act before (``cover(_:under:_:)``) is no move, and is not copied.
    ///
    /// A copy is for ONE pane: its key starts as the move's key does (the act's number), and ends with that pane's
    /// number after ``copyMark``. A pane that moves alone again keeps its copies: its hole goes with each move that
    /// it still has.
    ///
    /// An act before can have made a mask under ANOTHER pane, and ``cut(_:by:_:)`` uses it again under this one. Its
    /// parts then have a move that the cut gave it in an act of which this pane has no animation on its layer: a
    /// move for the other pane's hole, and a copy for this pane would add to a hole that is not this pane's hole.
    /// So a mask that is used again under another pane is as on the base branch alone: each copy for a pane that is
    /// not this act's one pane comes off its part here, and the mask gets no copy for this pane.
    ///
    /// The limit that stays: a mask whose parts have moves of that act gets nothing. A mask that the same pane cut in
    /// that act has them from there (a zoom, then its unzoom). A mask that is used again under another pane keeps the
    /// moves that ``cut(_:by:_:)`` gave it for that pane's hole: its hole is not at this pane's rect until those
    /// moves, and this pane's own moves of acts before, end.
    private func carryMoves(of change: Change, toTheMasksOf hosts: [PaneHostView]) {
        let pane = Self.copyMark + String(Int(bitPattern: ObjectIdentifier(change.host)))
        for part in hosts.flatMap({ ($0.clipView.layer?.mask as? PaneHoleMaskLayer)?.sublayers ?? [] }) {
            for key in part.animationKeys() ?? [] where key.contains(Self.copyMark) && !key.hasSuffix(pane) {
                part.removeAnimation(forKey: key)
            }
        }
        guard let layer = change.host.layer else { return }
        let own = ((covers[ObjectIdentifier(change.host)]?.acts ?? []) + [serial]).map { "pane.commit.\($0)." }
        var before: [String: (point: CGPoint, size: CGSize, like: CABasicAnimation)] = [:]
        for key in layer.animationKeys() ?? [] where key.hasPrefix("pane.commit.") && !own.contains(where: { key.hasPrefix($0) }) {
            guard let path = ["position", "bounds.size"].first(where: { key.hasSuffix("." + $0) }),
                  let animation = layer.animation(forKey: key) as? CABasicAnimation, animation.isAdditive,
                  let from = animation.fromValue as? NSValue else { continue }
            let act = String(key.dropLast(path.count))
            var had = before[act] ?? (point: CGPoint.zero, size: CGSize.zero, like: animation)
            if path == "position" { had.point = from.pointValue } else { had.size = from.sizeValue }
            before[act] = had
        }
        // The start of a key up to its act's number. A mask with a move, not a copy, of an act that is not one of
        // this pane's acts is used again under another pane: it gets no copy.
        func actStart(_ key: String) -> String { key.split(separator: ".").prefix(3).joined(separator: ".") }
        let mine = Set((layer.animationKeys() ?? []).map { actStart($0) }).union(["pane.commit.\(serial)"])
        let fresh = hosts.filter { host in
            let keys = ((host.clipView.layer?.mask as? PaneHoleMaskLayer)?.sublayers ?? []).flatMap { $0.animationKeys() ?? [] }
            return !keys.contains { $0.hasPrefix("pane.commit.") && !$0.contains(Self.copyMark) && !mine.contains(actStart($0)) }
        }
        let anchor = layer.anchorPoint
        for (act, had) in before {
            // The pane with that move alone is `far` from its place and `had.size` larger. A part's distance does not
            // depend on where the hole is or on the extent: a hole with room for that change gives it.
            let far = CGPoint(x: had.point.x - anchor.x * had.size.width, y: had.point.y - anchor.y * had.size.height)
            let hole = CGRect(x: 0, y: 0, width: abs(had.size.width) + 1, height: abs(had.size.height) + 1)
            let then = CGRect(x: far.x, y: far.y, width: hole.width + had.size.width, height: hole.height + had.size.height)
            let starts = PaneHoleMaskLayer.rects(around: then, in: hole.union(then)), ends = PaneHoleMaskLayer.rects(around: hole, in: hole.union(then))
            for host in fresh {
                guard let parts = (host.clipView.layer?.mask as? PaneHoleMaskLayer)?.sublayers, parts.count == ends.count,
                      !parts.contains(where: { part in (part.animationKeys() ?? []).contains { $0.hasPrefix(act) } }) else { continue }
                for (part, (start, end)) in zip(parts, zip(starts, ends)) {
                    let size = CGSize(width: start.width - end.width, height: start.height - end.height), spot = part.anchorPoint
                    let point = CGPoint(x: start.minX - end.minX + spot.x * size.width, y: start.minY - end.minY + spot.y * size.height)
                    let values = [("position", point != .zero, NSValue(point: point), NSValue(point: .zero)),
                                  ("bounds.size", size != .zero, NSValue(size: size), NSValue(size: .zero))]
                    for (path, isFar, from, to) in values where isFar {
                        guard let copy = had.like.copy() as? CABasicAnimation else { continue }
                        copy.keyPath = path
                        copy.fromValue = from
                        copy.toValue = to
                        part.add(copy, forKey: act + path + pane)
                        moved.append((layer: part, key: act + path + pane))
                    }
                }
            }
        }
    }

    /// Ends the own move of an act before on `host`, a pane that this act keeps under a pane with no ground: its
    /// layer, its inner clip, its ring and its copy of the window's picture are at their places from this pass. A
    /// window, and the mask of ``cut(_:by:_:)``, is made for a pane at rest; a pane that still moved would show past
    /// it, inside the pane over it. The pane's window of an act before stays, and each animation of this act.
    private func endOwnMove(of host: PaneHostView) {
        let kept = ((covers[ObjectIdentifier(host)]?.acts ?? []) + [serial]).map { "pane.commit.\($0)." }
        let ring: CALayer? = host.chrome.layer
        let copy: CALayer? = sheets.first(where: { $0.host === host })?.picture
        var layers: [CALayer] = [host.layer, host.clipView.layer, ring, copy].compactMap { $0 }
        layers += ring?.sublayers ?? []
        for layer in layers {
            for key in layer.animationKeys() ?? [] where key.hasSuffix(".position") || key.hasSuffix(".bounds.size") {
                let isOfAnActBefore = key.hasPrefix("pane.commit.") && !kept.contains(where: { key.hasPrefix($0) })
                if isOfAnActBefore { layer.removeAnimation(forKey: key) }
            }
        }
    }

    /// Takes the window of the acts `acts` from `host`: its layer shows at its own place and size again.
    private func uncover(_ host: PaneHostView, of acts: [Int]) {
        guard let layer = host.layer else { return }
        for act in acts {
            for path in ["position", "bounds.origin", "bounds.size"] { layer.removeAnimation(forKey: "pane.commit.\(act).\(path)") }
        }
    }

    /// `layer` clips what is in it. It shows through a window that goes from `start` to `end` (its superlayer's
    /// coordinates), and what is in it stays where it is: the origin of its own coordinates goes with its place.
    /// `base`: where the layer shows with no animation of this act. The animations hold their end.
    private func window(_ layer: CALayer, _ token: MotionSpring, from start: CGRect, to end: CGRect, over base: CGRect) {
        let anchor = layer.anchorPoint
        func offsets(_ rect: CGRect) -> (place: CGPoint, origin: CGPoint, size: CGSize) {
            let origin = CGPoint(x: rect.minX - base.minX, y: rect.minY - base.minY)
            let size = CGSize(width: rect.width - base.width, height: rect.height - base.height)
            return (CGPoint(x: origin.x + anchor.x * size.width, y: origin.y + anchor.y * size.height), origin, size)
        }
        let from = offsets(start), to = offsets(end)
        if from.place != .zero || to.place != .zero {
            add("position", from: NSValue(point: from.place), to: NSValue(point: to.place), on: layer, token, holds: true)
        }
        if from.origin != .zero || to.origin != .zero {
            add("bounds.origin", from: NSValue(point: from.origin), to: NSValue(point: to.origin), on: layer, token, holds: true)
        }
        if from.size != .zero || to.size != .zero {
            add("bounds.size", from: NSValue(size: from.size), to: NSValue(size: to.size), on: layer, token, holds: true)
        }
    }
}
