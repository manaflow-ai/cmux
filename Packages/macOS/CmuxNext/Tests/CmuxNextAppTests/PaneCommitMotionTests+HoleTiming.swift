import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a second close key in a close's move: the hole of each mask that the second close makes
/// goes with the pane over it, each move with its own timing.
///
/// The pane that grows in the second close still has its move of the first close on its layer. The second close puts
/// a mask on the clip of each pane that left (`PaneCommitMotion+Under`), with a hole for the pane that grows. The
/// hole's parts get the second close's move, and a copy of the first close's move (`PaneCommitMotion+Cover`). A copy
/// has the timing of the move that it is a copy of, as that move reads back from the pane's layer, and not the
/// timing of the second close.
///
/// This file reads the animations as they are on the layers, and each layer's path by `MotionPath` (the math of the
/// render server) at media times. It reads no frame of the app, and it reads and waits for no clock.
extension PaneCommitMotionTests {
    /// When and how `animation` runs, with each field that gives it its time: 2 animations with the same fields are
    /// at the same part of their way at each time.
    static func timingFields(of animation: CABasicAnimation) -> String {
        let velocity = (animation as? CASpringAnimation).map { " velocity \($0.initialVelocity)" } ?? ""
        return "\(timing(animation))\(velocity) speed \(animation.speed) offset \(animation.timeOffset) repeats \(animation.repeatCount) "
            + "fill \(animation.fillMode.rawValue) removed at its end \(animation.isRemovedOnCompletion)"
    }

    /// The animations of the position and of the size of `layer` that the act `act` put on it.
    static func actMoves(_ act: Int, on layer: CALayer) -> [CABasicAnimation] {
        let keys = (layer.animationKeys() ?? []).filter { Self.act(of: $0) == act }
        return keys.compactMap { layer.animation(forKey: $0) as? CABasicAnimation }.filter { $0.keyPath == "position" || $0.keyPath == "bounds.size" }
    }

    /// How far each edge of `layer` (min x, min y, max x, max y, in its superlayer) is from its place at each of
    /// `times` (media times), by `MotionPath`: each animation of its position and of its size counts with its own
    /// start time, spring and duration. `now`: the start of an animation that has no start time yet. Nil: the layer
    /// has an animation that `MotionPath` does not read.
    static func farFromPlace(_ layer: CALayer, at times: [CFTimeInterval], now: CFTimeInterval) -> [[CGFloat]]? {
        let place = MotionPath(layer, "position", now: now), size = MotionPath(layer, "bounds.size", now: now)
        guard place.isExact, size.isExact else { return nil }
        let anchor = layer.anchorPoint
        func edges(_ point: CGPoint, _ size: CGPoint) -> [CGFloat] {
            let x = point.x - anchor.x * size.x, y = point.y - anchor.y * size.y
            return [x, y, x + size.x, y + size.y]
        }
        let rest = edges(place.model, size.model)
        return times.map { time in zip(edges(place.value(at: time), size.value(at: time)), rest).map { $0 - $1 } }
    }

    /// The start time that the row gives the first close's moves. No machine's clock is there in a run (it is more
    /// than 3 years after the machine's start), so no commit puts such a move at its end.
    static let startByHand: CFTimeInterval = 100_000_000

    /// Does by hand what a commit to a render tree does in the app: each animation of the pane motion on `layer`,
    /// on its sublayers and on their masks that has no start time yet gets the start time `time`. An animation that
    /// is on a layer does not change, so a copy with the start time goes on the layer under the same key. Returns
    /// how many animations got the start time.
    static func giveStartTime(_ time: CFTimeInterval, toTheMovesUnder layer: CALayer) -> Int {
        var count = 0
        for key in layer.animationKeys() ?? [] where key.hasPrefix("pane.commit.") {
            guard let animation = layer.animation(forKey: key), animation.beginTime == 0,
                  let copy = animation.copy() as? CAAnimation else { continue }
            copy.beginTime = time
            layer.add(copy, forKey: key)
            count += 1
        }
        for below in (layer.sublayers ?? []) + [layer.mask].compactMap({ $0 }) {
            count += giveStartTime(time, toTheMovesUnder: below)
        }
        return count
    }

    /// A hold of the close key in a column of 3 rows and in a row of 3 panes, as in
    /// ``afterASecondCloseKeyEachPaneThatLeftShowsWholeInTheRoomThatNoPaneHas(_:)``: the first key closes the middle
    /// pane, and 2 panes move, so no pane gets a mask. The second key closes the pane that has the focus, in that
    /// move: ONE pane grows, with its move of the first close still on its layer, and each of the 2 panes that left
    /// gets a new mask. After the second key:
    /// 1. For each of the 2 acts, each move of that act on a part of each mask has the timing fields of the pane's
    ///    own move of that act, as both read back from their layers: the start time, the duration, the spring, the
    ///    speed and the time offset. Each mask has a move of each act.
    /// 2. At 3 media times, each edge of each mask's hole is as far from its place as that edge of the pane that
    ///    grows is from its place, by `MotionPath`. The times are from the start times on the layers, not from a
    ///    clock: the second close's start, and a quarter and a half of a close's time after it.
    ///
    /// Between the 2 keys the row gives each animation of the first close a start time by hand
    /// (``giveStartTime(_:toTheMovesUnder:)``), as a commit to a render tree gives one in the app before a second
    /// key comes. The row makes no commit: with a commit there (`CATransaction.flush()`), on a test host whose
    /// window has no render tree, the first close's moves were no longer on the layers at the second key. The row
    /// prints the start times that it reads. It proves that a copy keeps the start time that its move has on its
    /// layer, and each copy's fields and values. It does not prove that a commit gives a start time, and it does
    /// not prove the phase on a screen.
    @Test(arguments: ["3 rows", "3 side by side"])
    func afterASecondCloseKeyTheHoleOfEachNewMaskGoesWithThePaneOverItEachMoveOnItsOwnTiming(_ scene: String) throws {
        let between = Self.between(scene)
        let harness = Commit.Harness(between.screens, focused: between.closes, holds: false) { $0.splitSizingOverride = between.even ? .even : .halve }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let first = try #require(rest[between.closes], "SETUP: the pane that closes does not show at rest")

        _ = try #require(harness.model.showPaneClose(between.closes), "SETUP: the model does not show the close of \(between.closes)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let layers = try #require(screen.layer, "SETUP: the screen has no layer")
        let given = Self.giveStartTime(Self.startByHand, toTheMovesUnder: layers)
        try #require(given > 0, "SETUP: the first close put no animation with the start time 0 on a layer of the screen")
        let opening = Self.acts(on: screen)
        try #require(opening.count == 1, "SETUP: after the first close the panes have the moves of \(opening.count) acts, not of 1: \(opening)")
        let openingMoves = screen.subviews.compactMap { ($0 as? PaneHostView)?.layer }.flatMap { Self.actMoves(opening[0], on: $0) }
        let stamped = Set(openingMoves.map(\.beginTime))
        let isStamped = stamped == [Self.startByHand]
        try #require(isStamped, "SETUP: the moves of the first close on the layers of the panes that move read the start times \(stamped.sorted()), not \(Self.startByHand) alone")
        let next = try #require(harness.model.focusedPane, "SETUP: no pane has the focus after the first close")
        let second = try #require(rest[next], "SETUP: the pane \(next) that has the focus after the first close did not show at rest")
        try #require(second !== first, "SETUP: the pane that closed keeps the focus")
        try #require(first.clipView.layer?.mask == nil && second.clipView.layer?.mask == nil,
                     "SETUP: the first close put a mask on a pane of the second close: the second close's mask is not new")
        _ = try #require(harness.model.showPaneClose(next), "SETUP: the model does not show the close of \(next) in the first close's move")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(first.isLeaving && !first.isHidden && second.isLeaving && !second.isHidden, "SETUP: the move does not keep the 2 panes that left")
        let acts = Self.acts(on: screen)
        try #require(acts.count == 2, "SETUP: the panes have the moves of \(acts.count) acts, not of the 2 closes: \(acts)")
        let grows = Self.hosts(of: screen).values.filter { host in !host.isLeaving && host.layer.map { !Self.actMoves(acts[1], on: $0).isEmpty } ?? false }
        try #require(grows.count == 1, "SETUP: the second close makes \(grows.count) panes move, not 1")
        let layer = try #require(grows[0].layer, "SETUP: the pane that grows has no layer")
        try #require(!Self.actMoves(acts[0], on: layer).isEmpty, "SETUP: the pane that grows in the second close has no move of the first close on its layer")
        var masks: [(name: String, parts: [CALayer])] = []
        for (name, host) in [("first", first), ("second", second)] {
            let mask = try #require(host.clipView.layer?.mask as? PaneHoleMaskLayer, "SETUP: the second close put no mask on the clip of the pane of the \(name) close")
            let parts = mask.sublayers ?? []
            try #require(parts.count == 4, "SETUP: the mask on the pane of the \(name) close has \(parts.count) parts, not 4")
            masks.append((name: name, parts: parts))
        }

        // 1. The timing fields.
        var begins: [[CFTimeInterval]] = [], copies = 0
        for act in acts {
            let own = Self.actMoves(act, on: layer)
            let fields = Set(own.map { Self.timingFields(of: $0) })
            try #require(fields.count == 1, "SETUP: the moves of act \(act) on the pane that grows have \(fields.count) timings: \(fields.sorted())")
            var read = Set(own.map(\.beginTime))
            for mask in masks {
                let onParts = mask.parts.flatMap { Self.actMoves(act, on: $0) }, at = "the mask on the pane of the \(mask.name) close"
                #expect(!onParts.isEmpty, "\(at) has no move of act \(act) on its parts: its hole does not go with that move of the pane over it")
                if act == acts[0] { copies += onParts.count }
                read.formUnion(onParts.map(\.beginTime))
                let other = Set(onParts.map { Self.timingFields(of: $0) }).subtracting(fields)
                #expect(other.isEmpty, "\(at) has moves of act \(act) with the timing \(other.sorted()); the pane's own move of that act has \(fields.sorted())")
            }
            begins.append(read.sorted())
        }

        // 2. The hole and the pane, at 3 media times from the start times on the layers: the second close's start, and
        // a quarter and a half of a close's time after it. The second close's moves have no start time yet (the row
        // gave them none): they start one frame after the first close's start, as the row's 2 keys do.
        // No clock is read: a slow machine does not put the first close's move at its end before these times.
        // A set-up check says that each of the 3 times is before the end of the first close's move on the pane that
        // grows: from that end on check 2 reads the second close's move alone.
        let starts: [CFTimeInterval] = begins.map { read in
            guard let last = read.last, last > 0 else { return 0 }
            return layer.convertTime(last, to: nil)
        }
        let now = starts[1] > 0 ? starts[1] : starts[0] + Self.dt
        let times = [0, Self.close.time / 4, Self.close.time / 2].map { now + $0 }
        let firstEnds = Self.actMoves(acts[0], on: layer).map { starts[0] + $0.duration / Double(max($0.speed, Float.ulpOfOne)) }
        let firstEnd = try #require(firstEnds.min(), "SETUP: the pane that grows has no move of the first close: check 2 has no end to read")
        let after = times.map { $0 - starts[0] }
        let inside = starts[0] > 0 && times.allSatisfy { $0 < firstEnd }
        try #require(inside, "SETUP: check 2 is void: the 3 times are \(after) s after the first close's start, and its move ends \(firstEnd - starts[0]) s after it")
        let pane = try #require(Self.farFromPlace(layer, at: times, now: now), "SETUP: `MotionPath` does not read each animation on the layer of the pane that grows")
        for mask in masks {
            var far: [[[CGFloat]]] = []
            for part in mask.parts {
                let read = try #require(Self.farFromPlace(part, at: times, now: now), "SETUP: `MotionPath` does not read each animation on a part of the mask on the pane of the \(mask.name) close")
                far.append(read)
            }
            for index in times.indices {
                // The hole's edges: the max x of the part on the left, the max y of the part above, the min x of the
                // part on the right, the min y of the part below (`PaneHoleMaskLayer`: above, below, left, right).
                let hole = [far[2][index][2], far[0][index][3], far[3][index][0], far[1][index][1]]
                let apart = zip(hole, pane[index]).map { abs($0 - $1) }.max() ?? 0
                #expect(apart < 0.01, """
                    \(times[index] - now) s after the second close's start, the edges of the hole of the mask on the pane of the \(mask.name) close are \(hole) pt \
                    from their places (min x, min y, max x, max y), and the edges of the pane that grows are \(pane[index]) pt from theirs: \
                    \(apart) pt apart
                    """)
            }
        }
        let oneStart = begins[0] == [Self.startByHand]
        print("ROW (HOLE TIMING): \(scene): the start times read back from the layers of the pane that grows and of the parts of the 2 masks:",
              "the first close's moves \(begins[0]), the second close's moves \(begins[1]); copies of the first close's move on the parts: \(copies);",
              "the 3 times are \(times.map { (($0 - starts[0]) * 10000).rounded() / 10000 }) s after the first close's start;",
              "at the 3 times the pane that grows is \(pane.map { $0.map { ($0 * 100).rounded() / 100 } }) pt from its place (min x, min y, max x, max y).",
              "The row gave \(given) animations of the first close the start time \(Self.startByHand) by hand before the second key.",
              oneStart ? "Each copy of a move of the first close reads that start time."
                  : "NOT ONE START TIME: a move of the first close or a copy of it reads another start time.")
    }
}
