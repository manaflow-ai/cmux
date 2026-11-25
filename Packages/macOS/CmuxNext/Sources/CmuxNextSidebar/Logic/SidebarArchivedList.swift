/// One row of Settings > Sidebar > Archived Workspaces (cmux#51635): an archived workspace (archived itself, or a
/// member of an archived group) or an archived link, tab or app row. The sidebar draws none of them
/// (`SidebarLayout+ArchiveSection`); this list is where a person opens, restores or deletes them, as ChatGPT's
/// Settings > Data controls > Archived chats.
public nonisolated struct SidebarArchivedEntry: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case workspace
        /// A link, tab or app row of the sidebar document (``SidebarListItem``).
        case item
    }

    public var kind: Kind
    /// The workspace id, or the document item id of an item.
    public var id: String
    public var title: String
    /// The group it sits in, nil when loose.
    public var group: String?
    /// The computer it is on; nil for an item.
    public var machine: String?

    public init(kind: Kind, id: String, title: String, group: String? = nil, machine: String? = nil) {
        (self.kind, self.id, self.title, self.group, self.machine) = (kind, id, title, group, machine)
    }
}

public nonisolated struct SidebarArchivedList {
    public nonisolated init() {}
    /// Every archived row of `sections` in sidebar order, each workspace once. Pinned keeps its rows in the sidebar,
    /// so the list skips it, as the layout does.
    public static func entries(in sections: [SidebarSection]) -> [SidebarArchivedEntry] {
        var entries: [SidebarArchivedEntry] = []
        var seen: Set<String> = []
        for section in sections where section.id != .pinned && section.id != .custom(SidebarDocStore.pinnedSection) {
            let machine = section.machine?.name
            func add(_ ws: SidebarWorkspace, group: String?) {
                guard ws.isArchived, seen.insert(ws.id.rawValue).inserted else { return }
                entries.append(SidebarArchivedEntry(kind: .workspace, id: ws.id.rawValue, title: ws.title, group: group, machine: machine))
            }
            func add(_ item: SidebarListItem, group: String?) {
                guard item.isArchived, seen.insert("item:" + item.id).inserted else { return }
                entries.append(SidebarArchivedEntry(kind: .item, id: item.id, title: item.title, group: group))
            }
            for node in section.nodes {
                switch node {
                case let .workspace(ws): add(ws, group: nil)
                case let .item(item): add(item, group: nil)
                case let .group(group):
                    for member in group.members {
                        switch member {
                        case let .workspace(ws): add(ws, group: group.name)
                        case let .item(item): add(item, group: group.name)
                        }
                    }
                }
            }
        }
        return entries
    }
}
