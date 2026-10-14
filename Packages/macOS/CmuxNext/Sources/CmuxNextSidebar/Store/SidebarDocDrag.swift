public import CoreGraphics
import Foundation

/// The App's half of a drag on the sidebar document (sidebar-v2 S5): the
/// document item behind a list row, the machine section behind a list
/// section, the acceptance table (one FFI call per drag) and the drop (one
/// move intent). Set on `SidebarModel.docDrag` only while the document is
/// active; nil keeps the older drop resolver.
@MainActor
public struct SidebarDocDrag {
    /// The item a workspace or group row draws; nil when it has none.
    public var item: (SidebarRowKey) -> String?
    /// The machine section a list section draws.
    public var section: (SectionID) -> String?
    /// What a drop of these items may do beside each row (`drag_begin`).
    public var begin: ([String]) -> [String: SidebarDocAcceptance]
    /// The drop: one move, one undo step.
    public var drop: ([String], SidebarDocTarget) -> Void

    public init(item: @escaping (SidebarRowKey) -> String?, section: @escaping (SectionID) -> String?,
                begin: @escaping ([String]) -> [String: SidebarDocAcceptance], drop: @escaping ([String], SidebarDocTarget) -> Void) {
        self.item = item
        self.section = section
        self.begin = begin
        self.drop = drop
    }

    /// The items a drag payload moves, in order; nil when one has no item.
    public func items(_ payload: DragPayload) -> [String]? {
        let keys: [SidebarRowKey] = switch payload {
        case .workspaces(let ids): ids.map(SidebarRowKey.workspace)
        case .group(let group): [.group(group)]
        }
        let items = keys.compactMap(item)
        return items.count == keys.count ? items : nil
    }

    /// The drag geometry over `layout`'s rows (the list as drawn without
    /// the dragged rows and the gap): one slot per workspace, group and
    /// section row; tab and folder rows take no drop.
    public func geometry(_ layout: SidebarLayout, width: CGFloat, acceptance: [String: SidebarDocAcceptance]) -> (SidebarDragGeometry, [String: SidebarRow]) {
        var slots: [SidebarDragGeometry.Slot] = []
        var rows: [String: SidebarRow] = [:]
        for row in layout.rows {
            guard let section = section(row.section) else { continue }
            let frame = CGRect(x: 0, y: row.y, width: width, height: row.height)
            switch row.key {
            case .workspace, .group:
                guard let id = item(row.key) else { continue }
                var parent: String?
                var kind = SidebarDragGeometry.Slot.Kind.row
                if case .group = row.key { kind = .group } else { parent = row.group.flatMap { item(.group($0)) } }
                slots.append(.init(key: id, item: id, section: section, parent: parent, frame: frame, kind: kind))
                rows[id] = row
            case .section, .emptySection:
                slots.append(.init(key: section, item: nil, section: section, frame: frame, kind: .section))
                rows[section] = row
            case .tab, .folder:
                continue
            }
        }
        return (SidebarDragGeometry(slots: slots, acceptance: acceptance), rows)
    }

    /// The anchor target of a list position (index counted without the moved items).
    public func target(_ position: DropPosition, moving: [String], model: SidebarModel) -> SidebarDocTarget? {
        guard let section = section(position.section), let shown = model.section(position.section) else { return nil }
        let siblings: [String] = if let group = position.group {
            (model.group(group)?.workspaces ?? []).compactMap { item(.workspace($0.id)) }
        } else {
            shown.nodes.compactMap { node in
                switch node {
                case .workspace(let workspace): item(.workspace(workspace.id))
                case .group(let group): group.id.rawValue
                }
            }
        }
        return SidebarDocStore.target(section: section, parent: position.group?.rawValue, index: position.index, siblings: siblings, moving: Set(moving))
    }

    /// The anchor target of a band position: `index` among `section`'s items in `layout`.
    public static func target(_ section: LayoutSectionID, index: Int, moving: [String], layout: SidebarLayoutDocument) -> SidebarDocTarget {
        let siblings = layout.section(section)?.items.map(\.id.rawValue) ?? []
        return SidebarDocStore.target(section: section.rawValue, index: index, siblings: siblings, moving: Set(moving))
    }

    /// The list's drop look for `hit` (the gap or the highlighted group).
    public static func display(_ hit: SidebarDragGeometry.Hit, row: SidebarRow) -> DropTarget {
        switch (hit.zone, row.key) {
        case (.into, .group(let group)):
            return .intoGroup(group)
        case (_, .section(let section)), (_, .emptySection(let section)):
            return .position(DropPosition(section: section, index: 0))
        case (_, .group):
            return .position(DropPosition(section: row.section, index: row.siblingIndex + (hit.zone == .after ? 1 : 0)))
        default:
            return .position(DropPosition(section: row.section, group: row.group, index: row.siblingIndex + (hit.zone == .after ? 1 : 0)))
        }
    }
}
