import Foundation

/// Each machine's nodes while a `SidebarDocProjection` is built. A group is held apart until the end, so adding a
/// member writes it in place: no copy of the machine's nodes or of the group's members per member row.
nonisolated struct SidebarDocMachineNodes {
    private enum Slot {
        case node(SidebarDocProjection.Node)
        case group(Int)
    }
    private var slots: [String: [Slot]] = [:]
    private var groups: [SidebarDocProjection.Group] = []
    /// The last group listed with an id, by session: a member row goes to it (nested groups list flat, in order).
    private var lastGroup: [String: [String: Int]] = [:]

    mutating func append(_ node: SidebarDocProjection.Node, session: String) {
        slots[session, default: []].append(.node(node))
    }

    mutating func append(_ group: SidebarDocProjection.Group, session: String) {
        lastGroup[session, default: [:]][group.id] = groups.count
        slots[session, default: []].append(.group(groups.count))
        groups.append(group)
    }

    mutating func add(_ id: String, _ item: SidebarDocItem, toGroup parent: String, session: String) {
        guard let at = lastGroup[session]?[parent] else { return }
        groups[at].add(id, item)
    }

    func nodes() -> [String: [SidebarDocProjection.Node]] {
        slots.mapValues { slots in
            slots.map { slot in
                switch slot {
                case let .node(node): node
                case let .group(index): .group(groups[index])
                }
            }
        }
    }
}
