public import CmuxNextDesign
import Foundation

/// The list's sections as the sidebar document places items (sidebar-v2):
/// one list draws every section's rows with the same row views, the same
/// layout and the same drag. The App maps each machine's workspaces and
/// groups (a group of Pinned or a custom section rides with its machine,
/// `SidebarDocSections`); this puts them where the document has them:
/// - a machine section lists its links, tabs and apps between its rows,
///   in document order (`SidebarNode.item`);
/// - every other section (Pinned, custom, app sections) is a list section
///   (`SectionID.custom`) at its own place in the document order: its items
///   draw in its own arrangement (`SidebarRowKey.block`), and its groups
///   leave their machine and list there as header and member rows. A kept
///   group no other window lists an open workspace of lists there too; one
///   whose open workspace another window lists belongs to it (#25776).
extension SidebarDocProjection {
    /// `sections` arranged as this document places items; `drag` names each row's item and each list section's document section.
    @MainActor public func arrange(_ sections: [SidebarSection], drag: SidebarDocDrag) -> [SidebarSection] {
        let projection = self
        let bandIDs = Set(projection.bandGroups.map(\.id))
        let elsewhere = projection.bandGroupsNotListedHere(drag: drag)
        var pulled: [String: SidebarGroup] = [:]
        var arranged = sections.map { section in
            var section = section.unwrappedHostGroup()
            section.nodes.removeAll { node in
                guard case .group(let group) = node, bandIDs.contains(group.id.rawValue) else { return false }
                // A group whose members sit on more than one machine comes once per machine: one group again.
                if var seen = pulled[group.id.rawValue] {
                    seen.workspaces += group.workspaces
                    pulled[group.id.rawValue] = seen
                } else {
                    pulled[group.id.rawValue] = group
                }
                return true
            }
            if section.machine != nil {
                section.nodes = Self.machineNodes(section, projection, drag: drag)
                // A machine section the person made a remote group keeps its header in one list.
                section.isHostGroup = drag.section(section.id).flatMap { projection.hostGroups.contains($0) } ?? false
                // It draws as one group (user 2026-10-31, Chief msg 19277).
                if section.isHostGroup { section = section.wrappedAsHostGroup() }
            }
            return section
        }
        // A list arranged before (a fold passes the shown list back in) holds the document's sections
        // already: their groups are pulled above, and they come again below, once.
        let made = Set(projection.layout.sections.filter { $0.content != .workspaces }.map(\.id.rawValue))
        arranged.removeAll { if case .custom(let id) = $0.id { made.contains(id) } else { false } }
        // Every section of the document in its order: the sections before the machine lists (Pinned,
        // custom, app sections) draw their items in their own arrangement (a block) and their groups as
        // list rows; the machine lists follow; a section after them lists its groups only.
        var before: [SidebarSection] = [], after: [SidebarSection] = []
        var passedMachines = false
        for layoutSection in projection.layout.sections {
            if layoutSection.content == .workspaces {
                passedMachines = true
                continue
            }
            let id = layoutSection.id.rawValue
            let nodes = projection.bandGroups.filter { $0.section == id }.compactMap { group -> SidebarNode? in
                if let shown = pulled[group.id] { return .group(shown) }
                // Not listed here: another window lists an open workspace of it, or it is another space's; else none
                // does (its header alone, also while its last one closes or a new one waits for its window's row).
                return elsewhere.contains(group.id) ? nil : .group(Self.emptyGroup(group))
            }
            guard !passedMachines || !nodes.isEmpty else { continue }
            let section = SidebarSection(kind: .custom(SidebarCustomSection(id: id, title: layoutSection.title, showsTitle: false)), nodes: nodes)
            if passedMachines { after.append(section) } else { before.append(section) }
        }
        let at = arranged.firstIndex { $0.machine != nil } ?? arranged.count
        arranged.insert(contentsOf: before, at: at)
        arranged += after
        return Self.markingArchived(Self.withMemberItems(arranged, projection, drag: drag), projection, drag: drag)
    }

    /// `sections` with each archived row marked (`isArchived`): it draws dimmed (archiving-DESIGN.md).
    @MainActor private static func markingArchived(_ sections: [SidebarSection], _ projection: SidebarDocProjection,
                                                   drag: SidebarDocDrag) -> [SidebarSection] {
        // Every row, also with none archived: a list arranged before (a fold) may carry an old mark.
        let archived = projection.archived
        func mark(_ workspace: SidebarWorkspace) -> SidebarWorkspace {
            var workspace = workspace
            workspace.isArchived = drag.item(.workspace(workspace.id)).map { archived.contains($0) } ?? false
            return workspace
        }
        func mark(_ item: SidebarListItem) -> SidebarListItem {
            var item = item
            item.isArchived = archived.contains(item.id)
            return item
        }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.map { node in
                switch node {
                case .workspace(let workspace): return .workspace(mark(workspace))
                case .item(let item): return .item(mark(item))
                case .group(var group):
                    group.isArchived = archived.contains(group.id.rawValue)
                    group.workspaces = group.workspaces.map(mark)
                    group.items = group.items.map { SidebarGroupItem(item: mark($0.item), after: $0.after) }
                    return .group(group)
                }
            }
            return section
        }
    }

    /// `sections` with each group's url, tab and app members (`SidebarGroup.items`): a member follows the
    /// workspace member it follows in the document, else the nearest one before it that lists here.
    @MainActor private static func withMemberItems(_ sections: [SidebarSection], _ projection: SidebarDocProjection,
                                                   drag: SidebarDocDrag) -> [SidebarSection] {
        var byGroup: [String: Group] = [:]
        for group in projection.bandGroups where !group.listed.isEmpty { byGroup[group.id] = group }
        for nodes in projection.machines.values {
            for case .group(let group) in nodes where !group.listed.isEmpty { byGroup[group.id] = group }
        }
        guard !byGroup.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.map { node in
                guard case .group(var group) = node, let placed = byGroup[group.id.rawValue] else { return node }
                var shown: [String: WorkspaceID] = [:]
                for workspace in group.workspaces { if let item = drag.item(.workspace(workspace.id)) { shown[item] = workspace.id } }
                group.items = placed.listed.map { listed in
                    var anchor: WorkspaceID?
                    if let after = listed.after, let index = placed.memberItems.firstIndex(of: after) {
                        anchor = placed.memberItems[...index].reversed().lazy.compactMap { shown[$0] }.first
                    }
                    return SidebarGroupItem(item: titled(listed.item), after: anchor)
                }
                return .group(group)
            }
            return section
        }
    }

    /// A built-in's or app's row takes its own title when the document stores none.
    @MainActor private static func titled(_ listed: SidebarListItem) -> SidebarListItem {
        var listed = listed
        if listed.title == listed.ref.value, listed.ref.kind != LayoutItemRef.urlKind {
            listed.title = SidebarItemInfo.fallback(for: listed.ref).title
        }
        return listed
    }

    /// A machine section's nodes in document order with its link rows; a node
    /// the document does not place yet (adopt in flight) keeps its mapped slot.
    @MainActor private static func machineNodes(_ section: SidebarSection, _ projection: SidebarDocProjection, drag: SidebarDocDrag) -> [SidebarNode] {
        guard let docSection = drag.section(section.id),
              let session = projection.machineSections.first(where: { $0.value == docSection })?.key,
              let order = projection.machines[session],
              order.contains(where: { if case .link = $0 { true } else { false } }) else { return section.nodes }
        var byItem: [String: SidebarNode] = [:]
        for node in section.nodes {
            let item: String? = switch node {
            case .workspace(let workspace): drag.item(.workspace(workspace.id))
            case .group(let group): group.id.rawValue
            case .item(let listed): listed.id
            }
            if let item, byItem[item] == nil { byItem[item] = node }
        }
        // A mapped row the document does not place yet (a new workspace whose item is on the way) keeps
        // its mapped slot: right before the placed row that follows it there, so its item's arrival
        // moves nothing (plans/cmux-next/sidebar-ordering-DESIGN.md).
        var placedIDs = Set<SidebarNode.ID>()
        for entry in order {
            switch entry {
            case .workspace(_, let item): if let node = byItem[item] { placedIDs.insert(node.id) }
            case .group(let group): if let node = byItem[group.id] { placedIDs.insert(node.id) }
            case .link(let listed): if let node = byItem[listed.id] { placedIDs.insert(node.id) }
            }
        }
        var before: [SidebarNode.ID: [SidebarNode]] = [:]
        var waiting: [SidebarNode] = []
        for node in section.nodes {
            guard placedIDs.contains(node.id) else { waiting.append(node); continue }
            if !waiting.isEmpty { before[node.id] = waiting }
            waiting = []
        }
        var nodes: [SidebarNode] = []
        func append(_ node: SidebarNode) {
            nodes += before.removeValue(forKey: node.id) ?? []
            nodes.append(node)
        }
        for entry in order {
            switch entry {
            case .workspace(_, let item):
                if let node = byItem.removeValue(forKey: item) { append(node) }
            case .group(let group):
                if let node = byItem.removeValue(forKey: group.id) { append(node) }
            case .link(let listed):
                // A link row arranged before is this one again.
                byItem.removeValue(forKey: listed.id)
                append(.item(titled(listed)))
            }
        }
        // Unplaced rows after the last placed one keep their mapped order at the end.
        return nodes + waiting
    }

    /// The band groups holding an open workspace another window lists (`SidebarDocDrag.listedElsewhere`), themselves
    /// or in a group under them: they leave this window. It changes with window ownership alone, so the App redraws
    /// when it does (`SidebarRows.show`'s `elsewhere`).
    @MainActor public func bandGroupsListedElsewhere(drag: SidebarDocDrag) -> Set<String> {
        let parents = Dictionary(bandGroups.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var open = Set<String>()
        for group in bandGroups where group.openMembers.contains(where: drag.listedElsewhere) {
            var id: String? = group.id
            while let current = id, open.insert(current).inserted { id = parents[current] ?? nil }
        }
        return open
    }

    /// The band groups whose header this window leaves out when it lists none of their workspaces: the ones another
    /// window lists (`bandGroupsListedElsewhere`) and the ones of another space than `drag.room` (spaces.md), with the
    /// groups nested under those.
    @MainActor public func bandGroupsNotListedHere(drag: SidebarDocDrag) -> Set<String> {
        var hidden = bandGroupsListedElsewhere(drag: drag)
        guard drag.room != nil else { return hidden }
        var otherSpace = Set(bandGroups.filter { !$0.lists(inRoom: drag.room) }.map(\.id))
        // A group under another space's group leaves with it: a window never draws a child whose parent it leaves
        // out. Repeat until no group changes, so a deeper descendant follows whatever order `bandGroups` has.
        var changed = !otherSpace.isEmpty
        while changed {
            changed = false
            for group in bandGroups where !otherSpace.contains(group.id) {
                if let parent = group.parent, otherSpace.contains(parent) { changed = otherSpace.insert(group.id).inserted || changed }
            }
        }
        return hidden.union(otherSpace)
    }

    /// A kept group with no open member (Pinned keeps it): its header alone.
    @MainActor private static func emptyGroup(_ group: Group) -> SidebarGroup {
        // The confirmed fold (a fold's echo rebuilds no projection, `SidebarDocStore.groupFolds`).
        var made = SidebarGroup(id: GroupID(group.id), name: group.name, isCollapsed: SidebarDocStore.current?.groupFolds[group.id] ?? group.collapsed,
                                icon: group.icon.flatMap { WorkspaceIcon.parse($0) }, workspaces: [])
        made.tint = group.color.flatMap { GroupTint(wire: $0) } ?? .palette(.unset(id: group.id))
        // A group in Pinned reads as pinned, as one with members does (`SidebarDocMachines.model`): else its
        // header offers Pin Group again, which the sidebar refuses (#22259).
        made.isPinned = group.pinned
        made.parent = group.parent.map { GroupID($0) }
        made.depth = group.depth
        return made
    }
}

extension SidebarModel {
    /// A document item the list draws as a row (a link in a machine list), as a layout item a click runs.
    public func listedItem(_ id: LayoutItemID) -> LayoutItem? {
        for section in sections {
            for node in section.nodes {
                for item in node.listedItems where item.id == id.rawValue { // a group's member item too
                    return LayoutItem(id: id, ref: item.ref, label: item.title)
                }
            }
        }
        return nil
    }
}

extension SidebarDocStore {
    /// The document's item `id` at any depth (in a group or a machine section too), as a layout item.
    public func placedItem(_ id: LayoutItemID) -> LayoutItem? {
        drawnRecords.items[id.rawValue].map { LayoutItem(id: id, ref: SidebarDocProjection.ref($0.body, id: $0.id)) }
    }

    /// Whether the document as the sidebar draws it (the confirmed document and the changes not yet echoed, the
    /// mirror's rows with no group folded) holds an item showing `ref` at any depth (a band, a group, a machine list).
    /// Every window draws from this one document, whatever its own membership leaves out. Observable: an intent
    /// moves `version`, a batch `records` too. One mirror call per change.
    public func placesItem(with ref: LayoutItemRef) -> Bool {
        _ = version
        guard let rows = rows(SidebarViewRequest(live: Array(lastLive))) else { return false }
        return rows.contains { row in
            guard let id = row.item else { return false }
            return (records.items[id].map { SidebarDocProjection.ref($0.body, id: id) } ?? Self.pendingRef(id)) == ref
        }
    }

    /// The first document item (by id) showing `ref` at any depth, as a layout item.
    public func placedItem(with ref: LayoutItemRef) -> LayoutItem? {
        drawnRecords.items.values.sorted { $0.id < $1.id }.lazy
            .first { SidebarDocProjection.ref($0.body, id: $0.id) == ref }
            .map { LayoutItem(id: LayoutItemID($0.id), ref: ref) }
    }

    /// Stores the page icon address `known` gives for each url item (an open
    /// tab's favicon, learned by the App's favicon store) on the item, once
    /// per address: `item.update {patch: {icon_url}}`, no undo step.
    public func storeIconURLs(_ known: (String) -> String?) {
        guard isActive else { return }
        var ops: [[String: Any]] = []
        for item in records.items.values {
            guard case .url(let page, _) = item.body, let address = known(page), address != item.iconURL,
                  requestedIconURLs[item.id] != address else { continue }
            requestedIconURLs[item.id] = address
            ops.append(["op": "item.update", "id": item.id, "patch": ["icon_url": address]])
        }
        if !ops.isEmpty { send(ops: ops, title: Self.moveTitle, undoable: false) }
    }
}
