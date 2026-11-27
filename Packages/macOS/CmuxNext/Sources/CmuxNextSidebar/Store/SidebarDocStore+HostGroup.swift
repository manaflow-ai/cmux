public import CmuxNextDesign
import Foundation

/// Why New Subgroup plans no op (cmux-layout-reducer `sidebar_doc::plan`).
public nonisolated enum SidebarDocSubgroupRefusal: Error, Hashable, Sendable {
    /// The parent is not a group of the document.
    case unknownGroup
    /// The parent is already at the deepest level a group may have (16, the reducer's `MAX_GROUP_DEPTH`).
    case tooDeep
    /// The document is not shown yet.
    case unavailable
}

/// Remote groups and New Subgroup on the sidebar document (remote-groups-DESIGN.md slices 3 and 4). The reducer
/// plans the ops on the document as shown, pending changes included (`SidebarMirror.plan`).
extension SidebarDocStore {
    /// Marks the machine section of daemon session `session` a remote group (``hostGroupOps(session:title:)``)
    /// in one change with no undo step of its own; nothing when it already is one.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - title: the change's name (the undo menu and the refusal HUD).
    ///   - name: the group's name on its header; nil keeps the host's name.
    public func markHostGroup(session: String, title: String, name: String? = nil) {
        let ops = hostGroupOps(session: session, title: name)
        guard !ops.isEmpty else { return }
        send(ops: ops, title: title, undoable: false)
    }

    /// The `sidebar.apply` ops that make daemon session `session`'s machine section a remote group, named `title`
    /// when one is given: `section.update` of its section, or `section.add` of it when the document has none yet.
    /// A remote group that already exists is only renamed; empty when nothing changes.
    public func hostGroupOps(session: String, title: String? = nil) -> [[String: Any]] {
        var request: [String: Any] = ["plan": "host_group", "session": session]
        if let title { request["title"] = title }
        return (try? plan(request).get()) ?? []
    }

    /// The ops that turn daemon session `session`'s remote group back into rows of the one list (the section and its
    /// rows stay; only the header goes). Empty when its section is not a remote group.
    public func hostGroupRemovalOps(session: String) -> [[String: Any]] {
        (try? plan(["plan": "host_group", "session": session, "on": false]).get()) ?? []
    }

    /// The ops of New Subgroup: one `group.create` of a group `id` named `name` (the localized default when empty)
    /// with `color` inside `parent`, in `parent`'s section.
    public func subgroupOps(parent: GroupID, id: GroupID, name: String, color: GroupTint) throws(SidebarDocSubgroupRefusal) -> [[String: Any]] {
        let request: [String: Any] = ["plan": "subgroup", "parent": parent.rawValue, "id": id.rawValue, "name": SidebarGroup.named(name),
                                      "color": color.wire]
        switch plan(request) {
        case let .success(ops): return ops
        case let .failure(refusal):
            switch refusal.code {
            case "too_deep": throw .tooDeep
            case "unknown_group": throw .unknownGroup
            default: throw .unavailable
            }
        }
    }
}
