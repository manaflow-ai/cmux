#if DEBUG
import AppKit

// `debug.sidebar_nested_fixture` (nested-groups prototype): the look and drop mark of a capture scenario.
public extension SidebarContainerView {
    /// Shows `fixture`'s rails and its drag: the lifted row and the drop mark ("inside" or "between").
    func showNestedFixture(_ fixture: SidebarNestedFixture?) {
        let list = sidebarView.list
        list.legacyNestedRails = fixture?.legacyRails ?? false
        list.finishDrag()
        list.reload(animated: false)
        guard let fixture, let drop = fixture.drop else { return list.showNestedDrop(nil) }
        if let dragged = fixture.dragged, let row = list.displayed.row(for: .workspace(dragged)) {
            let frame = list.frame(for: row)
            let press = SidebarPress(key: row.key, point: NSPoint(x: frame.minX + 40, y: frame.midY))
            list.press = press
            list.beginDrag(press)
        }
        switch drop {
        case let .into(group):
            list.showNestedDrop(list.nestedDropMark(into: group))
        case let .after(workspace, level):
            list.showNestedDrop(list.nestedDropMark(beside: .workspace(workspace), after: true, level: level))
        }
    }
}
#endif
