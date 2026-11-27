import Foundation

/// The `sidebar_doc_listing` reducer op (`cmux-layout-reducer/src/sidebar_doc_listing.rs`): which band groups this
/// window leaves out, which rows draw archived or pinned in their group, and each group's sort. One call per pass
/// (an arrange, a redraw), never one per row.
nonisolated enum RustSidebarDocListing {
    static let op = "sidebar_doc_listing"

    /// A band group as the op reads it (`BandGroup`).
    struct BandGroup: Encodable {
        var id: String
        var section: String
        var parent: String?
        var room: String?
        var open_members: [String]
        var collapsed: Bool
    }

    /// One open member's key in `open_members` and `elsewhere` (a session and a workspace id; neither holds a newline).
    static func key(_ ref: SidebarDocWorkspaceRef) -> String { ref.sessionID + "\n" + ref.workspaceID }

    /// The projection's band groups and the open members another window lists (`SidebarDocDrag.listedElsewhere`).
    static func bandGroups(_ projection: SidebarDocProjection, drag: SidebarDocDrag) -> (groups: [BandGroup], elsewhere: [String]) {
        var elsewhere = Set<String>()
        let groups = projection.bandGroups.map { group in
            for member in group.openMembers where drag.listedElsewhere(member) { elsewhere.insert(key(member)) }
            return BandGroup(id: group.id, section: group.section, parent: group.parent, room: group.room,
                             open_members: group.openMembers.map(key), collapsed: group.collapsed)
        }
        return (groups, elsewhere.sorted())
    }

    struct ListedElsewhereRequest: Encodable {
        let op = "listed_elsewhere"
        var groups: [BandGroup]
        var elsewhere: [String]
    }

    struct NotListedHereRequest: Encodable {
        let op = "not_listed_here"
        var groups: [BandGroup]
        var elsewhere: [String]
        var room: String?
        var spaces: [String]?
        var listed_here: [String]
    }

    struct GroupsReply: Decodable { var groups: [String] }

    /// `{op: "marks", ...}`: each row's archived and pinned-in-group marks.
    struct MarksRequest: Encodable {
        struct Row: Encodable { var item: String?; var in_group: Bool }
        let op = "marks"
        var rows: [Row]
        var archived: [String]
        var pinned: [String]
    }

    struct MarksReply: Decodable {
        struct Mark: Decodable { var archived: Bool; var pinned_in_group: Bool }
        var marks: [Mark]
    }

    /// `{op: "sorts", ...}`: each group's sort.
    struct SortsRequest: Encodable {
        let op = "sorts"
        var groups: [String]
        var group_sorts: [String: String]
    }

    struct SortsReply: Decodable { var sorts: [String] }

    /// `{op: "ordered", ...}`: a sort's member order, as indexes.
    struct OrderedRequest: Encodable {
        struct Member: Encodable { var pinned: Bool; var archived: Bool; var name_rank: Int; var last_activity: Double? }
        let op = "ordered"
        var sort: String
        var members: [Member]
    }

    struct OrderedReply: Decodable { var order: [Int] }
}
