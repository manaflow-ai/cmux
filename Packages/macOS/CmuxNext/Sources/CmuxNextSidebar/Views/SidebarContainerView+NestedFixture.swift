#if DEBUG
import AppKit

// `debug.sidebar_nested_fixture` (nested-groups prototype): the look and held drag of a capture scenario.
public extension SidebarContainerView {
    /// Shows `fixture`'s rails and its drag: the lifted row held over its drop (a header's fill, or the gap).
    func showNestedFixture(_ fixture: SidebarNestedFixture?) {
        let list = sidebarView.list
        list.legacyNestedRails = fixture?.legacyRails ?? false
        list.finishDrag()
        list.reload(animated: false)
        guard let fixture, fixture.drop != nil else { return }
        if let dragged = fixture.dragged, let row = list.displayed.row(for: .workspace(dragged)) {
            let frame = list.frame(for: row)
            let press = SidebarPress(key: row.key, point: NSPoint(x: frame.minX + 40, y: frame.midY))
            list.press = press
            list.beginDrag(press)
            list.holdNestedFixtureDrop(fixture)
        }
    }
}
#endif
