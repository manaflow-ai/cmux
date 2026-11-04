import AppKit

/// FRAME OWNER REFACTOR S2B, rule C: a drag that starts while its edge springs takes over where the edge shows.
extension DividerDrag {
    /// The press of a drag that latched `motion.frameOwner.sharedEdges`, while the screen moves: the drag's value (a
    /// split's ratio, a column's width) goes to where its edge shows from its anchor, in the drag's own transaction, and
    /// the window lays that out now in a pass that moves nothing on screen (every frame keeps where it shows and its
    /// velocity). Each edge then gets its share of the change of speed that stops the dragged line against its anchor
    /// (`SharedEdgeMotion.Influence`), and the drag starts again from that layout (``start(_:at:)``), so the pointer's
    /// travel changes the pane 1:1. A cancel (a click, Escape) puts back the value the drag replaced
    /// (`DividerDragState.replaced`). Nothing to catch (the edge at rest from its anchor), a row edge, a canvas or a
    /// zoomed screen: the drag as before.
    func catchShown(_ kind: DividerHandleView.Kind, at windowPoint: NSPoint) {
        guard let drag = screen.activeDrag, drag.sharedEdges, !screen.context.reduceMotion, screen.canvasGeometry == nil, !screen.zoomed,
              screen.hasMotion, let caught = SharedEdgeMotion.caught(kind, on: screen) else { return }
        let layout = screen.layout, viewport = screen.bounds.size, style = screen.context.style, scale = screen.scale
        func geometry(_ value: DividerDragValue) -> ScreenGeometry {
            ScreenGeometry.compute(value.applied(to: layout), viewport: viewport, style: style, scale: scale)
        }
        let caughtGeometry = geometry(caught.value)
        let influence = caught.probes.lazy.compactMap {
            SharedEdgeMotion.Influence(kind, caught: caughtGeometry, probe: geometry($0), axis: caught.axis)
        }.first
        screen.activeDrag?.replaced = (caught.value.key, override(caught.value.key))
        screen.activeDrag?.touched = [caught.value.key]
        switch caught.value {
        case let .ratio(split, ratio): model.setSplitRatio(split, ratio: ratio, transaction: drag.transaction, phase: .changed)
        case let .width(column, width): model.setColumnWidth(column, width: width, transaction: drag.transaction, phase: .changed)
        }
        screen.activeDrag?.catching = true
        if let root = screen.superview as? LayoutRootView { root.syncWithModel() }
        screen.activeDrag?.catching = false
        if let influence {
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
        }
        screen.context.requestFrames()
        guard let current = screen.activeDrag, var fresh = start(kind, at: windowPoint) else { return }
        (fresh.transaction, fresh.touched, fresh.replaced, fresh.sharedEdges) = (current.transaction, current.touched, current.replaced, current.sharedEdges)
        (fresh.modifiers, fresh.lastWindowPoint, fresh.pressAt, fresh.lastRaw) = (current.modifiers, current.lastWindowPoint, current.pressAt, current.lastRaw)
        screen.activeDrag = fresh
    }
}

extension DividerDrag {
    /// The local value `key` shows over the daemon's now (a gesture's, or a released one the daemon has not confirmed).
    func override(_ key: DividerDragValueKey) -> LayoutModel.Override? {
        switch key {
        case let .split(split): model.splitOverrides[split]
        case let .column(column): model.widthOverrides[column]
        }
    }

    /// Puts back what a cancelled drag's catch replaced (`DividerDragState.replaced`): `override` for its key, or the
    /// daemon's value. A press that caught a springing divider and then was a click shows what it showed before.
    func putBack(_ replaced: (key: DividerDragValueKey, override: LayoutModel.Override?)) {
        switch replaced.key {
        case let .split(split): model.splitOverrides[split] = replaced.override
        case let .column(column): model.widthOverrides[column] = replaced.override
        }
        model.showOverlaid()
    }
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
