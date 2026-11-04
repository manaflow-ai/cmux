import AppKit
import CmuxNextDesign

/// FRAME OWNER REFACTOR S2B, rule D: a drag that starts while its edge springs holds the edge where it is drawn.
extension DividerDrag {
    /// The press of a drag that latched `motion.frameOwner.sharedEdges`, while the screen moves: the drag's value (a
    /// split's ratio, a column's width) goes to the value that rests its line on the pixel it is drawn on, in the drag's
    /// own transaction, and the window lays that out now in a pass that moves nothing on screen (every frame keeps where
    /// it shows and its velocity). Each edge then gets its share of the change of speed and place that stops the line on
    /// that pixel (`SharedEdgeMotion.Influence`), and the drag starts again from that layout (``start(_:at:)``),
    /// measuring the pointer from the drawn line: the pointer alone moves it, 1:1. A cancel (a click, Escape) sends
    /// again the unconfirmed release the catch replaced (`DividerDragState.replaced`), in a new transaction, so it
    /// settles or is refused as any release. A line at rest, a canvas or a zoomed screen: the drag as before. A press
    /// that cannot hold while the screen moves, or whose drag could shrink a pane that its spring takes far under its
    /// rest size past zero (also with any part of a clamp's spring taken off), turns the rule off for its drag (whole
    /// frames snap, as before S2B).
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
        // The probes go a few points either way from where the layout rests the line (a clamped value rests it at the
        // anchor's rest place plus the pane's minimum, not where it is drawn), so one of them moves it.
        let rested = SharedEdgeMotion.restLine(kind, axis: caught.axis, in: caughtGeometry) ?? caught.held
        let probes = [rested + SharedEdgeMotion.probeStep, rested - SharedEdgeMotion.probeStep].map { caught.valueAt($0 - caught.base) }
        let influence = probes.lazy.compactMap({
            SharedEdgeMotion.Influence(kind, caught: caughtGeometry, probe: geometry($0), axis: caught.axis)
        }).first
        if caught.catches, influence == nil { return turnSharedEdgesOff() }
        // No pane may show a negative size later in this drag (rule D keeps each edge's spring leftover): checked on
        // every pane, after the catch this press makes, along its spring's whole path, also without its share of a
        // clamp's spring (the line's leftover from where the layout rests it: the pointer can take it off).
        let spring = Motion.panes.policy.spring(screen.motionState.frameSpring)
        if SharedEdgeMotion.mayShowNegativeSize(screen.paneFrames, targets: caught.catches ? caughtGeometry.panes : nil,
                                                influence: caught.catches ? influence : nil, speedChange: caught.speedChange,
                                                clampLeftover: caught.catches ? caught.held - rested : 0,
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
            influence.apply(caught.speedChange, placeChange: caught.placeChange, to: &frame, from: influence.caught.panes[pane],
                            to: influence.probe.panes[pane])
            screen.paneFrames[pane] = frame
        }
        for handle in Array(screen.dividerFrames.keys) {
            guard var frame = screen.dividerFrames[handle] else { continue }
            let from = SharedEdgeMotion.Influence.target(handle, in: influence.caught)
            influence.apply(caught.speedChange, placeChange: caught.placeChange, to: &frame, from: from,
                            to: SharedEdgeMotion.Influence.target(handle, in: influence.probe))
            screen.dividerFrames[handle] = frame
        }
        screen.context.requestFrames()
        guard let current = screen.activeDrag, var fresh = start(kind, at: windowPoint) else { return }
        (fresh.transaction, fresh.touched, fresh.sharedEdges) = (current.transaction, current.touched, current.sharedEdges)
        (fresh.replaced, fresh.caughtValue, fresh.modifiers) = (current.replaced, current.caughtValue, current.modifiers)
        (fresh.lastWindowPoint, fresh.pressAt, fresh.lastRaw) = (current.lastWindowPoint, current.pressAt, current.lastRaw)
        // The pointer holds the line where it is drawn, also where the layout clamps its rest place (an extent under its
        // minimum from the anchor's rest place): `start` measured from that rest place; the drawn line is the grab.
        if let rest = SharedEdgeMotion.restLine(kind, axis: caught.axis, in: screen.baseGeometry) {
            fresh.grabOffset += rest - caught.held
            fresh.pressAt += rest - caught.held
        }
        if !fresh.modifiers.push, !fresh.modifiers.all {
            fresh.clampHold = SharedEdgeClamp(kind, axis: caught.axis, held: caught.held, base: caught.base, on: screen, influence: influence)
        }
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
