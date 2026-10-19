import Foundation

/// The Cloud group (`sidebar.cloudGroup`): new Cloud workspaces go into one
/// sidebar group. Each Cloud machine is its own machine section, and a
/// machine section holds only its own workspaces, so the group lives in an
/// untitled custom section of its own above the workspace list, where a
/// group may hold workspaces of several machines. Its ids are fixed, so
/// every window and every restart finds the same group. Only a new
/// workspace joins (the App calls this once, when the workspace is made):
/// one the person moves out is never moved back.
extension SidebarDocStore {
    /// The Cloud group's document item id.
    public static let cloudGroupID = "grp_cloud"
    /// The untitled custom section that holds the Cloud group.
    public static let cloudSectionID = "sec_cloud"

    /// The Cloud group's name.
    public static var cloudGroupName: String {
        String(localized: "sidebar.cloudGroup.name", defaultValue: "Cloud", bundle: .module)
    }

    /// The operations that put the new Cloud workspaces `refs` into the Cloud
    /// group, making its section and the group when they are not there; nil
    /// when none of them is to move.
    ///
    /// A workspace `records` already places in a group (the person picked
    /// one) stays there; one it does not place yet is adopted in the same
    /// `sidebar.apply`. A new section goes right above `listSection` (the
    /// first machine section), else first in the middle region.
    public static func cloudGroupOps(_ refs: [SidebarDocWorkspaceRef], records: SidebarDocRecords,
                                     listSection: String?) -> [[String: Any]]? {
        var ops: [[String: Any]] = []
        var moving: [String] = []
        for ref in refs {
            if let item = records.item(for: ref) {
                if item.parent == nil && item.section != Self.cloudSectionID { moving.append(item.id) }
            } else {
                ops.append(["op": "adopt", "refs": [["session_id": ref.sessionID, "workspace_id": ref.workspaceID]]])
                moving.append(Self.adoptedID(ref))
            }
        }
        guard !moving.isEmpty else { return nil }
        if let group = records.items[Self.cloudGroupID] {
            ops.append(["op": "move", "items": moving, "to": ["section": group.section, "parent": Self.cloudGroupID]])
            return ops
        }
        if records.sections[Self.cloudSectionID] == nil {
            var place: [String: Any] = ["region": SidebarRegion.middle.rawValue]
            if let listSection { place["before"] = listSection } // above the workspace list
            let list = SectionArrangement.list
            ops.append(["op": "section.add", "place": place, "section": [
                "id": Self.cloudSectionID, "kind": ["type": "custom"], "shows_title": false, "region": SidebarRegion.middle.rawValue,
                "look": SectionLook.list.rawValue, "arrangement": list.layout.rawValue, "align": list.align.rawValue,
            ] as [String: Any]])
        }
        ops.append(["op": "group.create", "id": Self.cloudGroupID, "name": Self.cloudGroupName, "color": GroupColor.blue.rawValue,
                    "items": moving, "to": ["section": Self.cloudSectionID]])
        return ops
    }

    /// Puts the new Cloud workspaces `refs` into the Cloud group
    /// (``cloudGroupOps(_:records:listSection:)``) in one change with no undo step of its own;
    /// false when the document is not live or none of them is to move.
    @discardableResult
    public func joinCloudGroup(_ refs: [SidebarDocWorkspaceRef]) -> Bool {
        guard isActive, let ops = Self.cloudGroupOps(refs, records: records, listSection: shown?.machineOrder.first) else { return false }
        send(ops: ops, title: Self.moveTitle, undoable: false)
        return true
    }
}
