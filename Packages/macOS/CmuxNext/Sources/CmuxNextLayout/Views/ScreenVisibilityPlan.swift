import AppKit

/// Visibility from the motion plan (chrome-parity p03-rendering-106). A visibility pass reads every place a pane
/// shows between now and its rest (``sweep(shown:rest:track:)``), so the pass at a change's apply covers both ends
/// of its motion: a pane that enters is visible in the change's turn, one that leaves stays visible until the
/// motion lands, and the pass at the landing narrows to the rest. This plan is the rest of what the pass reads:
/// the rests (one reconcile pass), each camera's rest, the bounds, and whether a motion is in flight. A display
/// frame that changes none of it changes no pane's presence, so the root runs no pass on it
/// (`LayoutRootView.updateVisibilityIfPlanChanged()`). A camera a pan holds is left out: the pan's own events run
/// the pass when a pane enters or leaves (`LayoutRootView+Scroll`, `ScreenContentView.panKeepsVisibility`).
/// Chromium decides occlusion on committed geometry, not on each frame of a compositor animation
/// (`cc/trees/occlusion_tracker.cc` walks the committed tree; `cc/animation/animation_host.h` ticks off it).
nonisolated struct ScreenVisibilityPlan: Equatable {
    var view: ObjectIdentifier
    var layoutPass: Int
    var bounds: CGRect
    var strip: CGFloat?
    var rows: [ColumnID: CGFloat]
    var areas: [SplitID: CGFloat]
    var inFlight: Bool
    var flinging: Bool
}

extension ScreenVisibilityPlan {
    /// `screen`'s plan now.
    @MainActor init(_ screen: ScreenContentView) {
        self.init(view: ObjectIdentifier(screen), layoutPass: screen.reconcilePasses, bounds: screen.bounds,
                  strip: screen.isUserScrolling ? nil : screen.restStripShift,
                  rows: screen.rowScrolls.compactMapValues { $0.state.isGestureActive ? nil : $0.state.spring.target },
                  areas: screen.areaScrolls.compactMapValues { $0.state.isGestureActive ? nil : $0.state.spring.target },
                  inFlight: screen.hasMotion || !screen.renderTracks.panes.isEmpty, flinging: screen.stripContainer.fling != nil)
    }

    /// The union of where a pane shows now (`shown`), where it rests (`rest`) and where each render-server spring
    /// that carries it started (`track`, around both).
    static func sweep(shown: CGRect, rest: CGRect, track: RenderSpringTrack?) -> CGRect {
        var sweep = shown.union(rest)
        for start in (track?.starts(around: rest) ?? []) + (track?.starts(around: shown) ?? []) { sweep = sweep.union(start) }
        return sweep
    }
}

extension ColumnScrollState {
    /// Where this camera rests: its spring's target, or its value while a pan holds it.
    var restOffset: CGFloat { isGestureActive ? spring.value : spring.target }
}

extension RenderSpringTrack {
    /// Where each of the track's springs started, around `rest` (each one's offset is what showed then, less the rest).
    func starts(around rest: CGRect) -> [CGRect] {
        segments.map { segment in
            CGRect(x: rest.minX + segment.offset.x, y: rest.minY + segment.offset.y,
                   width: max(0, rest.width + segment.offset.width), height: max(0, rest.height + segment.offset.height))
        }
    }
}

/// What a layout root last reported of its panes' presence, and the active screen's plan that pass read.
struct PanePresenceReport {
    private(set) var visible: Set<PaneID> = []
    private(set) var keepAlive: Set<PaneID> = []
    /// The plan the last pass read; nil while the root was not live.
    private(set) var plan: ScreenVisibilityPlan?
    /// Passes, cumulative (`debug.layout_counters` `update_visibility`): a spring wants <= 2 (p03-rendering DC2).
    private(set) var passes: UInt64 = 0

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
