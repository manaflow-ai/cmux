public import CmuxNextDesign
import Foundation

/// The `sidebar.apply` ops of "New Subgroup" (remote-groups-DESIGN.md slice 3): one `group.create`
/// inside `parent`, in `parent`'s section. The document allows ``SidebarDocSubgroupPlan/maxDepth``
/// levels of groups (host > project > branch), so a third-level group plans nothing and says why,
/// rather than sending an op the daemon refuses with `nesting`.
///
/// ```swift
/// let plan = SidebarDocSubgroupPlan(parent: group, id: .make(), name: "", color: .green, records: store.records)
/// if let ops = plan.ops { store.send(ops: ops, title: title) }
/// ```
public nonisolated struct SidebarDocSubgroupPlan {
    /// Why no op is planned.
    public enum Refusal: Hashable, Sendable {
        /// `parent` is not a group of the document.
        case unknownGroup
        /// `parent` is already at the deepest level a group may have.
        case tooDeep
    }

    /// The most levels of groups one tree may have (the reducer's `MAX_GROUP_DEPTH`).
    public static let maxDepth = 3

    /// The ops to send, or nil when ``refusal`` is set.
    public let ops: [[String: Any]]?
    /// Why ``ops`` is nil.
    public let refusal: Refusal?

    /// Plans a group `id` named `name` (the localized default when empty) with `color` inside `parent`.
    /// - Parameters:
    ///   - parent: the group the new group goes in.
    ///   - id: the new group's id.
    ///   - name: its name; empty takes ``SidebarGroup/named(_:)``'s default.
    ///   - color: its palette color.
    ///   - records: the document as the mirror holds it.
    public init(parent: GroupID, id: GroupID, name: String, color: GroupColor, records: SidebarDocRecords) {
        guard let group = records.items[parent.rawValue], case .group = group.body else {
            (ops, refusal) = (nil, .unknownGroup)
            return
        }
        var level = 1
        var seen: Set<String> = [group.id]
        var above = group.parent
        while let id = above, seen.insert(id).inserted, let item = records.items[id] {
            level += 1
            above = item.parent
        }
        guard level < Self.maxDepth else {
            (ops, refusal) = (nil, .tooDeep)
            return
        }
        let op: [String: Any] = [
            "op": "group.create", "id": id.rawValue, "name": SidebarGroup.named(name), "color": color.rawValue,
            "items": [String](), "to": ["section": group.section, "parent": group.id],
        ]
        (ops, refusal) = ([op], nil)
    }
}
