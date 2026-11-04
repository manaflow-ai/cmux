import AppKit
import CmuxNextDesign

/// FRAME OWNER REFACTOR S2B, rule C: a drag that starts while its edge springs takes over where the edge shows.
extension DividerDrag {
    /// The press of a drag that latched `motion.frameOwner.sharedEdges`, while the screen moves: the drag's value (a
    /// split's ratio, a column's width) goes to where its edge shows from its anchor, in the drag's own transaction, and
    /// the window lays that out now in a pass that moves nothing on screen (every frame keeps where it shows and its
    /// velocity). Each edge then gets its share of the change of speed that stops the dragged line against its anchor
    /// (`SharedEdgeMotion.Influence`), and the drag starts again from that layout (``start(_:at:)``), so the pointer's
    /// travel changes the pane 1:1. A cancel (a click, Escape) sends again the unconfirmed release the catch replaced
    /// (`DividerDragState.replaced`), in a new transaction, so it settles or is refused as any release. Nothing to
    /// catch (the edge at rest from its anchor), a canvas or a zoomed screen: the drag as before. A press that cannot
    /// catch while the screen moves, or whose drag would shrink a pane that still shows far under its rest size past
    /// zero, turns the rule off for its drag (whole frames snap, as before S2B).
    func catchShown(_ kind: DividerHandleView.Kind, at windowPoint: NSPoint) {
        guard let drag = screen.activeDrag, drag.sharedEdges else { return }
        guard !screen.context.reduceMotion, screen.canvasGeometry == nil, !screen.zoomed else { return }
        let caught: SharedEdgeMotion.Caught
        switch SharedEdgeMotion.press(kind, on: screen) {
        case let .caught(found): caught = found
        case .cannotCatch: return turnSharedEdgesOff()
        }
        let layout = screen.layout, viewport = screen.bounds.size, style = screen.context.style
        func geometry(_ value: DividerDragValue) -> ScreenGeometry {
            ScreenGeometry.compute(value.applied(to: layout), viewport: viewport, style: style, scale: 0)
        }
        let caughtGeometry = geometry(caught.value)
        let influence = caught.probes.lazy.compactMap({
            SharedEdgeMotion.Influence(kind, caught: caughtGeometry, probe: geometry($0), axis: caught.axis)
        }).first
        if caught.catches, influence == nil { return turnSharedEdgesOff() }
        // The caught value, laid out as the screen will (on its pixel grid), must put the line's rest place where it
        // shows from its anchor, within the shared-edge tolerance: a value the layout clamps (an extent under a minimum,
        // past the ratio range) or rounds further would leave the line springing under a still pointer. Such a press
        // takes the drag from before S2B.
        if caught.catches {
            let installed = ScreenGeometry.compute(caught.value.applied(to: layout), viewport: viewport, style: style, scale: screen.scale)
            guard let rest = SharedEdgeMotion.Influence.target(kind, in: screen.baseGeometry),
                  let now = SharedEdgeMotion.Influence.target(kind, in: installed) else { return turnSharedEdgesOff() }
            let moved = caught.axis == .horizontal ? now.minX - rest.minX : now.minY - rest.minY
            if abs(moved - caught.lineMove) >= 0.5 { return turnSharedEdgesOff() }
        }
        // No pane may show a negative size later in this drag (rule C keeps each edge's spring leftover): checked on
        // every pane, after the catch this press makes, along its spring's whole path.
        let spring = Motion.panes.policy.spring(screen.motionState.frameSpring)
        if SharedEdgeMotion.mayShowNegativeSize(screen.paneFrames, targets: caught.catches ? caughtGeometry.panes : nil,
                                                influence: caught.catches ? influence : nil, speedChange: caught.speedChange,
                                                minimum: style.minimumPaneSize, spring: spring) {
            return turnSharedEdgesOff()
        }
        guard caught.catches, let influence else { return }
        // The value the layout showed before the catch, when a local one (a release the daemon has not confirmed): a
        // cancel sends it again, in a new transaction, so it lands as it would have.
        screen.activeDrag?.replaced = shownOverride(caught.value.key)
        screen.activeDrag?.caughtValue = caught.value
        screen.activeDrag?.touched = [caught.value.key]
        set(caught.value, transaction: drag.transaction, phase: .changed)
        screen.activeDrag?.catching = true
        if let root = screen.superview as? LayoutRootView { root.syncWithModel() }
        screen.activeDrag?.catching = false
        for pane in Array(screen.paneFrames.keys) {
            guard var frame = screen.paneFrames[pane] else { continue }
            influence.apply(caught.speedChange, to: &frame, from: influence.caught.panes[pane], to: influence.probe.panes[pane])
            screen.paneFrames[pane] = frame
        }
        for handle in Array(screen.dividerFrames.keys) {
            guard var frame = screen.dividerFrames[handle] else { continue }
            let from = SharedEdgeMotion.Influence.target(handle, in: influence.caught)
            influence.apply(caught.speedChange, to: &frame, from: from, to: SharedEdgeMotion.Influence.target(handle, in: influence.probe))
            screen.dividerFrames[handle] = frame
        }
        screen.context.requestFrames()
        guard let current = screen.activeDrag, var fresh = start(kind, at: windowPoint) else { return }
        (fresh.transaction, fresh.touched, fresh.sharedEdges) = (current.transaction, current.touched, current.sharedEdges)
        (fresh.replaced, fresh.caughtValue, fresh.modifiers) = (current.replaced, current.caughtValue, current.modifiers)
        (fresh.lastWindowPoint, fresh.pressAt, fresh.lastRaw) = (current.lastWindowPoint, current.pressAt, current.lastRaw)
        screen.activeDrag = fresh
    }

    /// A press that cannot catch while the screen moves: its drag is the drag from before S2B (whole frames snap to
    /// their rest place), which shows no negative size.
    private func turnSharedEdgesOff() {
        guard screen.hasMotion || screen.paneFrames.values.contains(where: \.moves) || screen.dividerFrames.values.contains(where: \.moves)
        else { return }
        screen.activeDrag?.sharedEdges = false
    }

    /// The local value `key` shows over the daemon's now, if any (a released drag the daemon has not confirmed).
    func shownOverride(_ key: DividerDragValueKey) -> DividerDragValue? {
        switch key {
        case let .split(split): model.splitOverrides[split].map { .ratio(split, $0.value) }
        case let .column(column): model.widthOverrides[column].map { .width(column, $0.value) }
        }
    }

    /// Writes `value` to the model in `transaction`.
    func set(_ value: DividerDragValue, transaction: LayoutTransactionID, phase: LayoutGesturePhase) {
        switch value {
        case let .ratio(split, ratio): model.setSplitRatio(split, ratio: ratio, transaction: transaction, phase: phase)
        case let .width(column, width): model.setColumnWidth(column, width: width, transaction: transaction, phase: phase)
        }
    }
}

extension AnimatedFrame {
    /// Some component still has a velocity (a spring can cross its target with speed: its rect is on target then).
    var moves: Bool { x.velocity != 0 || y.velocity != 0 || width.velocity != 0 || height.velocity != 0 }
}

extension DividerDragValue {
    /// `layout` with this value set.
    func applied(to layout: ScreenLayout) -> ScreenLayout {
        switch self {
        case let .ratio(split, ratio): layout.settingRatio(ratio, for: split)
        case let .width(column, width): layout.settingWidth(width, for: column)
        }
    }
}
