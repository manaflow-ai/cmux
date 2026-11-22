#if DEBUG
import AppKit

// `debug.sidebar_group_drag` (group drag captures, Lawrence 2026-10-23): a group header pressed and held through
// the drag path a pointer takes (`beginDrag`, `updateDrag`, `finishDrag`, `cancelDrag`), so a capture shows what a
// real drag shows at each pointer y. Fixture rows have no document items: the lift gives the list a document drag
// that names every row by its id and accepts every place (the app's drag path) and drops nothing; the caller puts
// the app's own back when the drag ends (`debug.sidebar_group_drag`).
public extension SidebarContainerView {
    /// One step of a held group drag capture.
    enum GroupDragFixtureStep: Sendable {
        /// Presses the header of `group` and lifts it.
        case lift(GroupID)
        /// Moves the pointer to list y `y` (at the x it pressed).
        case move(y: Double)
        /// Lets go (the drop) or cancels.
        case end(drop: Bool)
    }

    /// Runs `step` and answers where it pressed, the lifted card's frame and the open gap (list coordinates).
    func groupDragFixture(_ step: GroupDragFixtureStep) -> [String: Double] {
        let list = sidebarView.list
        switch step {
        case let .lift(group):
            list.cancelDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            guard let row = list.displayed.groupRow(group) else { return ["error": 1] }
            list.model.docDrag = SidebarDocDrag(item: { key in
                switch key {
                case let .workspace(id): id.rawValue
                case let .group(id): id.rawValue
                default: nil
                }
            }, section: { String(describing: $0) }, begin: { _ in [:] }, drop: { _, _ in })
            let frame = list.frame(for: row)
            let press = SidebarPress(key: row.key, point: NSPoint(x: frame.minX + 40, y: frame.midY))
            list.press = press
            list.beginDrag(press)
            return ["press_x": press.point.x, "press_y": press.point.y].merging(state(list)) { a, _ in a }
        case let .move(y):
            list.updateDrag(windowPoint: list.convert(NSPoint(x: (list.drag?.lift.frame.minX ?? 0) + 40, y: y), to: nil))
        case let .end(drop):
            if drop { list.finishDrag() } else { list.cancelDrag() }
        }
        return state(list)
    }

    private func state(_ list: SidebarListView) -> [String: Double] {
        var answer: [String: Double] = [:]
        if let card = list.drag?.lift.frame {
            (answer["card_y"], answer["card_height"]) = (card.minY, card.height)
        }
        if let gap = list.displayed.gapY { (answer["gap_y"], answer["gap_shift"]) = (gap, list.displayed.gapShift) }
        return answer
    }
}
#endif
