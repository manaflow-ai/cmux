import Foundation

/// The `sidebar.apply` ops that make a host's machine section a remote group
/// (remote-groups-DESIGN.md slice 4): `section.update {host_group: true}` on its
/// section, or `section.add` of that section, already a remote group, when the
/// document has none yet (a host just connected, no workspace adopted).
public nonisolated struct SidebarDocHostGroupPlan {
    /// The ops to send; empty when the section already is a remote group.
    public let ops: [[String: Any]]

    /// Plans the remote group of the machine whose daemon session is `session`.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - records: the document as the mirror holds it.
    public init(session: String, records: SidebarDocRecords) {
        let id = "sec_m_\(session)"
        if let section = records.sections[id] {
            ops = section.hostGroup ? [] : [["op": "section.update", "id": id, "patch": ["host_group": true]]]
        } else {
            ops = [["op": "section.add", "section": ["id": id, "kind": ["type": "machine", "session_id": session], "host_group": true]]]
        }
    }
}
