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
///   leave their machine and list there as header and member rows. An empty
///   kept group lists there too.
extension SidebarDocProjection {
    /// `sections` arranged as this document places items; `drag` names each row's item and each list section's document section.
    @MainActor public func arrange(_ sections: [SidebarSection], drag: SidebarDocDrag) -> [SidebarSection] {
        let projection = self
        let bandIDs = Set(projection.bandGroups.map(\.id))
        var pulled: [String: SidebarGroup] = [:]
        var arranged = sections.map { section in
            var section = section
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
            let nodes = projection.bandGroups.filter { $0.section == id }.map { SidebarNode.group(pulled[$0.id] ?? Self.emptyGroup($0)) }
            guard !passedMachines || !nodes.isEmpty else { continue }
            let section = SidebarSection(kind: .custom(SidebarCustomSection(id: id, title: layoutSection.title, showsTitle: false)), nodes: nodes)
            if passedMachines { after.append(section) } else { before.append(section) }
        }
        let at = arranged.firstIndex { $0.machine != nil } ?? arranged.count
        arranged.insert(contentsOf: before, at: at)
        arranged += after
        return Self.withMemberItems(arranged, projection, drag: drag)
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

    /// A kept group with no open member (Pinned keeps it): its header alone.
    @MainActor private static func emptyGroup(_ group: Group) -> SidebarGroup {
        // The confirmed fold (a fold's echo rebuilds no projection, `SidebarDocStore.groupFolds`).
        var made = SidebarGroup(id: GroupID(group.id), name: group.name, isCollapsed: SidebarDocStore.current?.groupFolds[group.id] ?? group.collapsed,
                                icon: group.icon.flatMap { WorkspaceIcon.parse($0) }, workspaces: [])
        made.tint = group.color.flatMap { GroupTint(wire: $0) } ?? .palette(.unset(id: group.id))
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
