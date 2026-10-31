#if DEBUG
import AppKit

// `debug.sidebar_nested_fixture`: a capture's drag is held where the scenario names, through the drag path a
// pointer takes (`updateDrag`), so the still shows what a real drag there shows (the gap or a header's fill).
extension SidebarListViewComponents {
    /// The y a capture puts the lifted card at: just over the drop the fixture names.
    func nestedDropY(_ fixture: SidebarNestedFixture) -> CGFloat? {
        switch fixture.drop {
        case let .into(group)?: displayed.groupRow(group).map { frame(for: $0).minY }
        case let .after(workspace, _)?: displayed.row(for: .workspace(workspace)).map { frame(for: $0).maxY }
        case nil: nil
        }
    }

    /// Moves the held drag to the drop `fixture` names, as a pointer there would.
    func holdNestedFixtureDrop(_ fixture: SidebarNestedFixture) {
        guard drag != nil, let drop = fixture.drop else { return }
        let point: NSPoint? = switch drop {
        case let .into(group):
            displayed.groupRow(group).map { NSPoint(x: frame(for: $0).midX, y: frame(for: $0).midY) }
        case let .after(workspace, level):
            displayed.row(for: .workspace(workspace)).map {
                NSPoint(x: inset + indent.offset(level: level, width: indentWidth) + 4, y: frame(for: $0).maxY - 1)
            }
        }
        guard let point else { return }
        updateDrag(windowPoint: convert(point, to: nil))
    }
}
#endif
