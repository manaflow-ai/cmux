import Foundation

/// The `sidebar.apply` ops that make a host's machine section a remote group
/// (remote-groups-DESIGN.md slice 4): `section.update {host_group: true}` on its
/// section, or `section.add` of that section, already a remote group, when the
/// document has none yet (a host just connected, no workspace adopted).
public nonisolated struct SidebarDocHostGroupPlan {
    /// The ops to send; empty when the section already is a remote group.
    public let ops: [[String: Any]]

    /// Plans marking (`on`) or unmarking the remote group of daemon session `session`. Unmarking
    /// leaves the section and its rows; only the header goes, back to the one list.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - records: the document as the mirror holds it.
    ///   - on: true marks, false unmarks.
    public init(session: String, records: SidebarDocRecords, on: Bool) {
        let id = "sec_m_\(session)"
        if on {
            ops = Self.markOps(id: id, session: session, records: records)
        } else {
            ops = records.sections[id]?.hostGroup == true ? [["op": "section.update", "id": id, "patch": ["host_group": false]]] : []
        }
    }

    /// Plans marking the remote group of daemon session `session`.
    public init(session: String, records: SidebarDocRecords) {
        ops = Self.markOps(id: "sec_m_\(session)", session: session, records: records)
    }

    private static func markOps(id: String, session: String, records: SidebarDocRecords) -> [[String: Any]] {
        if let section = records.sections[id] {
            return section.hostGroup ? [] : [["op": "section.update", "id": id, "patch": ["host_group": true]]]
        }
        return [["op": "section.add", "section": ["id": id, "kind": ["type": "machine", "session_id": session], "host_group": true]]]
    }
}
