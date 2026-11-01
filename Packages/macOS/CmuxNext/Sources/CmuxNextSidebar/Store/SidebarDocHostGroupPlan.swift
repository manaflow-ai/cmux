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

    /// Plans marking the remote group of daemon session `session`, named `title` when one is given
    /// (`cmux workspace group create --remote HOST --name N`): the header shows the title instead of
    /// the host's name. A remote group that already exists is only renamed; nil leaves its title.
    /// - Parameters:
    ///   - session: the host daemon's session id (its `registryID`).
    ///   - records: the document as the mirror holds it.
    ///   - title: the group's name; nil or empty keeps the host's name.
    public init(session: String, records: SidebarDocRecords, title: String? = nil) {
        ops = Self.markOps(id: "sec_m_\(session)", session: session, records: records, title: title.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func markOps(id: String, session: String, records: SidebarDocRecords, title: String? = nil) -> [[String: Any]] {
        if let section = records.sections[id] {
            var patch: [String: Any] = section.hostGroup ? [:] : ["host_group": true]
            if let title { patch["title"] = title }
            return patch.isEmpty ? [] : [["op": "section.update", "id": id, "patch": patch]]
        }
        var body: [String: Any] = ["id": id, "kind": ["type": "machine", "session_id": session], "host_group": true]
        if let title { body["title"] = title }
        return [["op": "section.add", "section": body]]
    }
}
