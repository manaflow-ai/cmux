import Foundation

// A new window starts clean (#26632): the sidebar document is one per home session, but each pin, group and link in
// it belongs to one window, `WindowBandOwnership`. These are the items a window can own and the filter that
// leaves out the rows of items another window owns. Built-ins and apps (Home, the App Store, the footer) are the
// sidebar's own chrome and list in every window; a workspace follows the window that lists it.
extension SidebarDocProjection {
    /// A document item one window owns: a top-level item of a band section, or a top-level group or link of a machine
    /// section. `ref` is a band item's layout ref (a workspace's names it); `members` are a group's workspaces.
    public nonisolated struct WindowItem: Hashable, Sendable {
        public var id: String
        public var ref: LayoutItemRef?
        public var members: [SidebarDocWorkspaceRef]
    }

    /// Every item a window can own, in document order.
    public nonisolated var windowItems: [WindowItem] {
        var result: [WindowItem] = []
        for section in layout.sections where section.content == .items {
            for item in section.items where Self.isWindowItem(item.ref) {
                result.append(WindowItem(id: item.id.rawValue, ref: item.ref, members: []))
            }
        }
        for group in bandGroups where group.parent == nil {
            result.append(WindowItem(id: group.id, ref: nil, members: group.members))
        }
        for session in machineOrder.compactMap({ id in machineSections.first { $0.value == id }?.key }) {
            for node in machines[session] ?? [] {
                switch node {
                case .workspace: continue
                case .group(let group) where group.parent == nil: result.append(WindowItem(id: group.id, ref: nil, members: group.members))
                case .group: continue
                case .link(let listed) where Self.isWindowItem(listed.ref): result.append(WindowItem(id: listed.id, ref: listed.ref, members: []))
                case .link: continue
                }
            }
        }
        return result
    }

    /// Built-ins and apps are the sidebar's chrome: every window lists them.
    nonisolated static func isWindowItem(_ ref: LayoutItemRef) -> Bool {
        ref.kind != LayoutItemRef.builtInKind && ref.kind != LayoutItemRef.appKind
    }

    /// Whether band group `id` leaves this window because another window owns the top-level group it sits in.
    @MainActor func bandGroupHidden(_ id: String, drag: SidebarDocDrag) -> Bool {
        guard !drag.hiddenItems.isEmpty else { return false }
        let parents = Dictionary(bandGroups.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var root = id
        while let parent = parents[root] ?? nil { root = parent }
        return drag.hiddenItems.contains(root)
    }

    /// A machine section's nodes without the groups and links another window owns (`SidebarDocDrag.hiddenItems`).
    /// A group with a workspace this window lists, itself or in a group under it, stays: it holds this window's rows.
    @MainActor static func withoutHiddenItems(_ nodes: [SidebarNode], drag: SidebarDocDrag) -> [SidebarNode] {
        guard !drag.hiddenItems.isEmpty else { return nodes }
        let groups = nodes.compactMap { node -> SidebarGroup? in if case .group(let group) = node { group } else { nil } }
        let parents = Dictionary(groups.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        func root(_ id: GroupID) -> GroupID {
            var root = id
            while let parent = parents[root] ?? nil { root = parent }
            return root
        }
        var holding = Set<GroupID>()
        for group in groups where !group.workspaces.isEmpty {
            var id: GroupID? = group.id
            while let current = id, holding.insert(current).inserted { id = parents[current] ?? nil }
        }
        return nodes.filter { node in
            switch node {
            case .workspace: true
            case .group(let group): holding.contains(group.id) || !drag.hiddenItems.contains(root(group.id).rawValue)
            case .item(let listed): !drag.hiddenItems.contains(listed.id)
            }
        }
    }
}
