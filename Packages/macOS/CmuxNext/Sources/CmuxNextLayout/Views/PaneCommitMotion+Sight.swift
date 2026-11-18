import AppKit

extension PaneCommitMotion {
    /// Which ways can show a point in a motion's time. The strip's camera moves each pane of the strip in x while it
    /// goes to its target, so a way can show when it has a point inside the screen's bounds at the camera's place in
    /// the pass that shows the act, at the camera's target, or between the two. The camera does not go outside of
    /// them: its spring passes no target (`SpringParameters.admitted`; `NoBounceSpringTests` steps each spring).
    /// That is one camera, in x. A column's rows have a camera in y and a scroll area has its own in x: while one of
    /// them is on its way, each way counts as one that can show.
    struct Sight {
        private let bounds: CGRect
        /// How far the strip's camera still moves each pane in x. Nil: a hand holds a camera, or a column's rows or
        /// a scroll area are on their way, so each way can show.
        private let travel: CGFloat?

        @MainActor
        init(of screen: ScreenContentView) {
            bounds = screen.bounds
            let held = screen.isUserScrolling || screen.rowScrolls.values.contains(where: \.state.isGestureActive)
                || screen.areaScrolls.values.contains(where: \.state.isGestureActive)
            travel = held || screen.rowsMoving || screen.areasMoving ? nil : screen.scroll.value - screen.scroll.target
        }

        /// Whether a pane or a divider can show a point of itself on `way`: its rect before the act united with its
        /// rect after it. A way that only touches an edge of the screen shows none.
        func meets(_ way: CGRect) -> Bool {
            guard let travel else { return true }
            let reach = way.union(way.offsetBy(dx: travel, dy: 0))
            return reach.maxX > bounds.minX && reach.minX < bounds.maxX && reach.maxY > bounds.minY && reach.minY < bounds.maxY
        }
    }
}
