import Foundation

/// How a group lists its workspaces (the group editor's Sort; the sidebar document's `extra.sort`).
/// Manual is the stored order (drag, Move to Top); the others list by a key and leave it as it is.
/// Leo 2026-11-03: "honestly i think we ought to be able to sort/filter the group alphabetically or smth..."
public nonisolated enum SidebarGroupSort: String, Hashable, Sendable, CaseIterable {
    case manual
    case name
    case recent

    /// The sort a stored value names; manual for none or one this build does not know.
    public init(wire value: Any?) {
        self = (value as? String).flatMap(Self.init(rawValue:)) ?? .manual
    }

    /// `members` in this sort. Pinned members stay first and archived ones last, as the document lists
    /// them; inside each band Name goes A to Z (Finder's order: case-insensitive, numbers by value) and
    /// Recent puts the latest activity first, members with none after them. Ties keep the stored order.
    public func ordered(_ members: [SidebarWorkspace], pinned: (SidebarWorkspace) -> Bool = { _ in false }) -> [SidebarWorkspace] {
        // The bands and keys are the `sidebar_doc_listing` op's (`ordered`); the name collation (Finder's order) stays
        // here: each member's place among the titles, equal titles sharing one.
        var ranks = [Int](repeating: 0, count: members.count)
        if self == .name {
            let byTitle = members.indices.sorted { members[$0].title.localizedStandardCompare(members[$1].title) == .orderedAscending }
            var rank = 0
            for (at, index) in byTitle.enumerated() {
                if at > 0, members[byTitle[at - 1]].title.localizedStandardCompare(members[index].title) != .orderedSame { rank += 1 }
                ranks[index] = rank
            }
        }
        let request = RustSidebarDocListing.OrderedRequest(sort: rawValue, members: members.indices.map { index in
            .init(pinned: pinned(members[index]), archived: members[index].isArchived, name_rank: ranks[index],
                  last_activity: members[index].lastActivity?.timeIntervalSince1970)
        })
        // When the op does not answer (or answers out of range), the stored order.
        guard let order = RustSidebarClient.call(RustSidebarDocListing.op, request, as: RustSidebarDocListing.OrderedReply.self)?.order,
              order.count == members.count, order.allSatisfy(members.indices.contains) else { return members }
        return order.map { members[$0] }
    }
}
