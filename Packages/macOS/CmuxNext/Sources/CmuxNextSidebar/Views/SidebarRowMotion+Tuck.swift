import AppKit
import CmuxNextDesign

// A workspace's tab lines tuck under its row as they fold, and come out from under it as they open
// (Leo 2026-10-27: "all the text gets compressed into that workspace zone, and you get, like,
// overlapping text for a split second. So I feel like you should just fade it a bit faster or a bit
// earlier in the movement, so that it looks like, you know, it, like, tucks under rather than it
// tucks over."). A folding line is gone before half of it is under the row, an opening line shows
// only once it is out from under it. Both draw below the workspace row
// while they move, so what is left of them passes behind it, never over it.
extension RowMotion {
    /// The latest a folding line is gone, and the earliest an opening one starts to show, as a part of the move.
    static let tuckFraction = 0.35
    /// The layer key the tuck's opacity runs under (tests read it).
    static let tuckKey = "cmux.tabTuck"
    /// The move (`SidebarListView.rowMoves`) a tuck belongs to, on its animation: an older move's end leaves a
    /// newer move's tuck in place.

    /// A tab line's key, else nil: only tab lines tuck (a workspace or group row keeps the shared fade).
    static func tucks(_ view: SidebarRowView) -> Bool {
        if case .tab = view.key { return true }
        return false
    }

    /// The frame of the workspace row a tab line folds under, else nil. A row that itself moves (a group or
    /// section opening or folding around it, so its tabs travel with it), or one an earlier move still carries, covers
    /// nothing (Codex review).
    static func cover(of line: SidebarRowView, rows: [SidebarRowKey: SidebarRowView], moving: Set<ObjectIdentifier>) -> NSRect? {
        guard case let .tab(workspace, _) = line.key, let row = rows[.workspace(workspace)],
              !moving.contains(ObjectIdentifier(row)), !isMidMove(row) else { return nil }
        return row.frame
    }

    /// Gives each folding or opening tab line its own fade in place of the shared one, timed by where the line is
    /// on the move's spring (`fadeTimes`), and draws it behind the other rows until the move ends (`untuck`). Each
    /// view's frame is where it starts, its rect where it ends. Returns the lines it took, so the shared fade
    /// leaves them out; none while fades are off (the shared fade, itself off then, sets their end alpha).
    /// Only lines that slide under or out from under a row tuck: a tab line opening or closing its own slot (a new
    /// or closed tab, at zero height there) keeps the shared fade.
    /// `header`: the frame of the workspace row a line belongs to. Only a line folding under or opening from under
    /// that row tucks (its fold y is the row's); a line its group or section header folds keeps the shared fade.
    static func tuck(appearing: [(SidebarRowView, NSRect)], leaving: [(SidebarRowView, NSRect)], move: Int = 0,
                     header: ((SidebarRowView) -> NSRect?)? = nil) -> Set<ObjectIdentifier> {
        // Without `header` (tests) every sliding line tucks; with it, a line whose row is gone or elsewhere does not.
        func underOwnRow(_ view: SidebarRowView, foldY: CGFloat) -> Bool {
            guard let header else { return true }
            return header(view).map { abs($0.minY - foldY) < 0.5 } ?? false
        }
        let lines = appearing.filter { tucks($0.0) && $0.0.frame.height > 0 && underOwnRow($0.0, foldY: $0.0.frame.minY) }.map { ($0.0, $0.1, true) }
            + leaving.filter { tucks($0.0) && $0.1.height > 0 && underOwnRow($0.0, foldY: $0.1.minY) }.map { ($0.0, $0.1, false) }
        guard !lines.isEmpty, Motion.sidebar.animatesFades else { return [] }
        let spring = Motion.sidebar.spring(.move)
        let settle = spring.settlingTime(within: 0.03)
        guard settle > 0 else { return [] }
        for (view, end, opening) in lines {
            // A fold turned around mid-move starts from the opacity the line shows now, never from a fixed end.
            let shown = Double(view.layer?.presentation()?.opacity ?? Float(view.alphaValue))
            // The end state at once, as the model value; the keyframes below draw the way there.
            Motion.withoutAnimation { view.alphaValue = opening ? 1 : 0 }
            view.layer?.zPosition = -1
            let height = opening ? end.height : view.frame.height
            var times = fadeTimes(opening: opening, travel: abs(end.minY - shownMinY(view)), height: height,
                                  header: header?(view)?.height ?? height, spring: spring, settle: settle)
            // A move cut short keeps its velocity (additive springs, `SidebarDragSpring`), so a line turned back
            // can first swing further under the row: an opening one stays hidden until the springs have all but
            // settled, not by the from-rest timing (Codex review). A folding one hiding early is never wrong.
            if opening, isMidMove(view) { times = [0, 0.9, 1, 1] }
            let values: [Double] = opening ? [shown, 0, 1, 1] : [shown, 0, 0]
            let now = CACurrentMediaTime()
            guard let layer = view.layer,
                  let fade = MotionPath.keyframes("opacity", values: values.map { NSNumber(value: $0) },
                                                  times: times.map { now + $0 * settle }, on: layer) else { continue }
            view.tuckMove = move
            layer.add(fade, forKey: tuckKey)
        }
        return Set(lines.map { ObjectIdentifier($0.0) })
    }

    /// The keyframe times of a line's fade, as parts of the move. A line `height` tall slides between its slot and
    /// the top of the workspace row (`header` tall), `travel` away. Folding, it is gone by the time half of it lies
    /// under the row (and by `tuckFraction` at the latest); opening, it shows only once 90% of it is out from under
    /// the row (and no sooner than `tuckFraction`), so no frame draws its text over the row's (Codex review: the
    /// first line out is still half under the row at 35% of the move, longer under a taller row).
    static func fadeTimes(opening: Bool, travel: CGFloat, height: CGFloat, header: CGFloat, spring: SpringParameters,
                          settle: Double) -> [Double] {
        guard travel > 0, height > 0 else { return opening ? [0, tuckFraction, min(1, tuckFraction + 0.25), 1] : [0, tuckFraction, 1] }
        if opening {
            let out = Double(max(0, header - height / 10) / travel)
            // No cap below the 90% point: a tall row keeps the line hidden that much longer (Codex review).
            let start = min(0.98, max(tuckFraction, time(toCover: min(1, out), spring) / settle))
            return [0, start, min(1, start + 0.2), 1]
        }
        let halfUnder = Double(max(0, travel - header + height / 2) / travel)
        return [0, min(tuckFraction, max(0.1, time(toCover: min(1, halfUnder), spring) / settle)), 1]
    }

    /// When a move on `spring` has covered `part` of its way (0...1), in seconds: the spring stepped from rest.
    static func time(toCover part: Double, _ spring: SpringParameters) -> Double {
        guard part > 0, spring.response > 0 else { return 0 }
        var value = SpringValue(0)
        value.target = 1
        var t = 0.0
        let dt = 1.0 / 240
        while Double(value.value) < part, t < 5 {
            value.step(dt, parameters: spring)
            t += dt
        }
        return t
    }

    /// Whether an earlier move's spring still carries `view` (it shows somewhere other than its model frame).
    /// Its spring animates the size as well as the place (`SidebarDragSpring`), so both count (Codex review).
    static func isMidMove(_ view: SidebarRowView) -> Bool {
        guard let layer = view.layer, let keys = layer.animationKeys(),
              keys.contains(where: { geometry.contains((layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath ?? "") }),
              let shown = layer.presentation()?.frame else { return false }
        let model = view.frame
        return abs(shown.minY - model.minY) > 0.5 || abs(shown.minX - model.minX) > 0.5
            || abs(shown.height - model.height) > 0.5 || abs(shown.width - model.width) > 0.5
    }

    private static let geometry: Set<String> = ["position", "bounds", "bounds.size", "bounds.origin", "frameOrigin", "frameSize"]

    /// Where `view` shows now: its spring's presentation while an earlier move still carries it there (the spring
    /// starts from it, `SidebarDragSpring`), else its frame.
    static func shownMinY(_ view: SidebarRowView) -> CGFloat {
        guard let layer = view.layer, let keys = layer.animationKeys(),
              keys.contains(where: { (layer.animation(forKey: $0) as? CABasicAnimation)?.keyPath == "position" }),
              let shown = layer.presentation() else { return view.frame.minY }
        return shown.frame.minY
    }

    /// Back in the rows' own drawing order once the move ended or was cut short. `move`: only a tuck of that move or
    /// an older one (an older move's end leaves a newer one's tuck running); nil, any.
    static func untuck(_ views: [SidebarRowView], move: Int? = nil) {
        for view in views where tucks(view) {
            // A newer move's tuck stays until that move ends, also once its fade has run out (Codex review).
            if let move, let tucked = view.tuckMove, tucked > move { continue }
            view.tuckMove = nil
            view.layer?.zPosition = 0
            view.layer?.removeAnimation(forKey: tuckKey)
        }
    }
}
