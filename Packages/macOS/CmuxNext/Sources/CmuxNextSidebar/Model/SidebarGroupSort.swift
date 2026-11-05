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
        guard self != .manual, members.count > 1 else { return members }
        func band(_ workspace: SidebarWorkspace) -> Int { pinned(workspace) ? 0 : workspace.isArchived ? 2 : 1 }
        return members.enumerated().sorted { a, b in
            let (bandA, bandB) = (band(a.element), band(b.element))
            if bandA != bandB { return bandA < bandB }
            switch self {
            case .manual:
                break
            case .name:
                let order = a.element.title.localizedStandardCompare(b.element.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .recent:
                switch (a.element.lastActivity, b.element.lastActivity) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}
