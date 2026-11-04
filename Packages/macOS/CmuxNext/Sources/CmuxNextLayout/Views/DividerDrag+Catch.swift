import AppKit

/// FRAME OWNER REFACTOR S2B, rule C: a drag that starts while its edge springs takes over where the edge shows.
extension DividerDrag {
    /// The press of a drag that latched `motion.frameOwner.sharedEdges`, while the screen moves: the drag's value (a
    /// split's ratio, a column's width) goes to where its edge shows from its anchor, in the drag's own transaction (a
    /// cancel takes it back), and the screen lays that out now in one pass that moves nothing on screen
    /// (`SharedEdgeMotion.Catch`): the dragged pane's size spring stops where it shows, the edges on its line ride the
    /// anchor. The drag then starts from that layout (``start(_:at:)``), so the pointer's travel changes the pane 1:1.
    /// Nothing to catch (the edge at rest from its anchor), a row edge, a canvas or a zoomed screen: the drag as before.
    func catchShown(_ kind: DividerHandleView.Kind, at windowPoint: NSPoint) {
        guard let drag = screen.activeDrag, drag.sharedEdges, !screen.context.reduceMotion, screen.canvasGeometry == nil, !screen.zoomed,
              screen.hasMotion, let caught = SharedEdgeMotion.caught(kind, on: screen) else { return }
        switch caught.value {
        case let .ratio(split, ratio): model.setSplitRatio(split, ratio: ratio, transaction: drag.transaction, phase: .changed)
        case let .width(column, width): model.setColumnWidth(column, width: width, transaction: drag.transaction, phase: .changed)
        }
        guard let layout = model.screens.first(where: { $0.id == screen.screenID })?.layout else { return }
        screen.activeDrag?.caught = caught.motion
        if screen.update(layout: layout, animated: false) { screen.context.requestFrames() }
        screen.activeDrag?.caught = nil
        guard var fresh = start(kind, at: windowPoint) else { return }
        (fresh.transaction, fresh.touched, fresh.modifiers) = (drag.transaction, [caught.value.key], drag.modifiers)
        (fresh.lastWindowPoint, fresh.pressAt, fresh.lastRaw) = (drag.lastWindowPoint, drag.pressAt, drag.lastRaw)
        screen.activeDrag = fresh
    }
}
