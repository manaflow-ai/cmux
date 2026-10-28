import AppKit
import CmuxNextDesign

/// Visibility from the motion plan. A visibility pass reads the whole way each
/// pane goes from now to its rest (``ScreenContentView/displayedSweeps()``), so the pass at a change's apply covers
/// both ends of its motion and every overshoot between: a pane that enters is visible in the change's turn, one that
/// leaves stays visible until the motion lands, and the pass at the landing narrows to the rest. This plan is the
/// rest of what the pass reads: the rests (one reconcile pass), each camera's rest, the bounds, and whether a motion
/// is in flight. A display frame that changes none of it changes no pane's presence, so the root runs no pass on it
/// (`LayoutRootView.updateVisibilityIfPlanChanged()`). A camera a pan holds is left out: the pan's own events run
/// the pass when a pane enters or leaves (`LayoutRootView+Scroll`, `ScreenContentView.panKeepsVisibility`).
/// Chromium's window occlusion works the same way (`ui/aura/window_occlusion_tracker.cc`): a window with a running
/// animation counts as visible and occludes nothing (`WindowIsAnimated`) over its whole animation, and occlusion
/// is computed again once the animation ends, not on each of its frames.
nonisolated struct ScreenVisibilityPlan: Equatable {
    var view: ObjectIdentifier
    var layoutPass: Int
    var bounds: CGRect
    var strip: CGFloat?
    var rows: [ColumnID: CGFloat]
    var areas: [SplitID: CGFloat]
    var inFlight: Bool
    var flinging: Bool
    /// A row or scroll area fling runs on the render server: the sweep holds its whole way.
    var scrollersFlinging: Bool
}

extension ScreenVisibilityPlan {
    /// `screen`'s plan now (a pass records it).
    @MainActor init(_ screen: ScreenContentView) {
        self.init(view: ObjectIdentifier(screen), layoutPass: screen.reconcilePasses, bounds: screen.bounds,
                  strip: screen.isUserScrolling ? nil : screen.restStripShift,
                  rows: screen.rowScrolls.compactMapValues { $0.state.isGestureActive ? nil : $0.state.spring.target },
                  areas: screen.areaScrolls.compactMapValues { $0.state.isGestureActive ? nil : $0.state.spring.target },
                  inFlight: Self.inFlight(screen), flinging: screen.stripContainer.fling != nil,
                  scrollersFlinging: Self.scrollersFlinging(screen))
    }

    /// Whether `screen`'s plan now is this one: `==` with ``init(_:)``'s plan, without building it (a display frame
    /// asks, so no dictionary is made). The motion walk goes last, and stops at the first frame on its way.
    @MainActor func matches(_ screen: ScreenContentView) -> Bool { // perf-hot: 4ms motion-frame
        guard view == ObjectIdentifier(screen), layoutPass == screen.reconcilePasses, bounds == screen.bounds,
              strip == (screen.isUserScrolling ? nil : screen.restStripShift),
              flinging == (screen.stripContainer.fling != nil),
              scrollersFlinging == Self.scrollersFlinging(screen) else { return false }
        var rowCount = 0
        for (id, scroll) in screen.rowScrolls where !scroll.state.isGestureActive {
            guard rows[id] == scroll.state.spring.target else { return false }
            rowCount += 1
        }
        var areaCount = 0
        for (id, scroll) in screen.areaScrolls where !scroll.state.isGestureActive {
            guard areas[id] == scroll.state.spring.target else { return false }
            areaCount += 1
        }
        return rowCount == rows.count && areaCount == areas.count && inFlight == Self.inFlight(screen)
    }

    @MainActor private static func scrollersFlinging(_ screen: ScreenContentView) -> Bool {
        screen.scrollerContainers.values.contains { $0.fling != nil }
    }

    @MainActor private static func inFlight(_ screen: ScreenContentView) -> Bool {
        !screen.renderTracks.panes.isEmpty || screen.hasMotion
    }
}

extension ColumnScrollState {
    /// Where this camera rests: its spring's target, or its value while a pan holds it.
    var restOffset: CGFloat { isGestureActive ? spring.value : spring.target }
}

/// What a layout root last reported of its panes' presence, and the active screen's plan that pass read.
struct PanePresenceReport {
    private(set) var visible: Set<PaneID> = []
    private(set) var keepAlive: Set<PaneID> = []
    /// The plan the last pass read; nil while the root was not live.
    private(set) var plan: ScreenVisibilityPlan?
    /// Passes, cumulative (`debug.layout_counters` `update_visibility`): a spring wants <= 2 (p03-rendering DC2).
    private(set) var passes: UInt64 = 0

    /// Whether the last pass read `screen`'s plan as it is now (nil: the root is not live).
    func isCurrent(for screen: ScreenContentView?) -> Bool { // perf-hot: 4ms motion-frame
        guard let screen else { return plan == nil }
        return plan?.matches(screen) == true
    }

    /// One pass over `screen` (nil while the root is not live: no pane shows): its presence changes, as
    /// ``record(visible:keepAlive:plan:)`` returns them.
    mutating func pass(_ screen: ScreenContentView?) -> [(PaneID, PanePresence)]? {
        var visible: Set<PaneID> = [], keepAlive: Set<PaneID> = []
        if let screen {
            let sweeps = screen.displayedSweeps()
            visible = screen.visiblePanes(sweeps)
            keepAlive = screen.keepAlivePanes(sweeps).union(visible)
            // A strip pan event inside this span reports nothing: it skips the pass (`LayoutRootView+Scroll`).
            screen.recordVisibilitySpan(sweeps)
        }
        return record(visible: visible, keepAlive: keepAlive, plan: screen.map { ScreenVisibilityPlan($0) })
    }

    /// One pass read `plan` and found `visible` and `keepAlive`: the presence changes, losses first (content
    /// leaving the band frees room before new content attaches), or nil when nothing changed.
    mutating func record(visible: Set<PaneID>, keepAlive: Set<PaneID>, plan: ScreenVisibilityPlan?) -> [(PaneID, PanePresence)]? {
        passes &+= 1
        self.plan = plan
        guard visible != self.visible || keepAlive != self.keepAlive else { return nil }
        var changes: [(PaneID, PanePresence)] = []
        for pane in self.keepAlive.union(keepAlive) {
            let after = PanePresence(pane, visible: visible, keepAlive: keepAlive)
            if PanePresence(pane, visible: self.visible, keepAlive: self.keepAlive) != after { changes.append((pane, after)) }
        }
        (self.visible, self.keepAlive) = (visible, keepAlive)
        return changes.sorted { $0.1.rank < $1.1.rank }
    }
}
