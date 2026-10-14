public import CmuxNextDesign
import Foundation

/// The list's sections as the sidebar document places items (sidebar-v2):
/// one list draws every section's rows with the same row views, the same
/// layout and the same drag. The App maps each machine's workspaces and
/// groups (a group of Pinned or a custom section rides with its machine,
/// `SidebarDocSections`); this puts them where the document has them:
/// - a machine section lists its links, tabs and apps between its rows,
///   in document order (`SidebarNode.item`);
/// - a group of Pinned or a custom section leaves its machine and lists in
///   that section's own list section (`SectionID.custom`), first in the
///   list, right under the band that draws the section's tiles. An empty
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
            if section.machine != nil { section.nodes = Self.machineNodes(section, projection, drag: drag) }
            return section
        }
        var listed: [SidebarSection] = []
        for group in projection.bandGroups {
            let node = SidebarNode.group(pulled[group.id] ?? Self.emptyGroup(group))
            if let last = listed.indices.last, listed[last].id == .custom(group.section) {
                listed[last].nodes.append(node)
            } else {
                let title = projection.layout.section(LayoutSectionID(group.section))
                listed.append(SidebarSection(kind: .custom(SidebarCustomSection(id: group.section, title: title?.title, showsTitle: false)),
                                             nodes: [node]))
            }
        }
        // First in the list, after the legacy Pinned section when one shows.
        let at = arranged.firstIndex { $0.machine != nil } ?? arranged.count
        arranged.insert(contentsOf: listed, at: at)
        return arranged
    }

    /// A machine section's nodes in document order with its link rows; nodes
    /// the document does not place yet (adopt in flight) follow last.
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
        var nodes: [SidebarNode] = []
        for entry in order {
            switch entry {
            case .workspace(_, let item):
                if let node = byItem.removeValue(forKey: item) { nodes.append(node) }
            case .group(let group):
                if let node = byItem.removeValue(forKey: group.id) { nodes.append(node) }
            case .link(var listed):
                if listed.title == listed.ref.value, listed.ref.kind != LayoutItemRef.urlKind {
                    listed.title = SidebarItemInfo.fallback(for: listed.ref).title
                }
                nodes.append(.item(listed))
            }
        }
        // Mapped rows the walk did not reach keep their mapped order after the placed ones.
        let reached = Set(nodes.map(\.id))
        return nodes + section.nodes.filter { !reached.contains($0.id) }
    }

    /// A kept group with no open member (Pinned keeps it): its header alone.
    private static func emptyGroup(_ group: Group) -> SidebarGroup {
        var made = SidebarGroup(id: GroupID(group.id), name: group.name, isCollapsed: group.collapsed,
                                icon: group.icon.flatMap { WorkspaceIcon.parse($0) }, workspaces: [])
        if let color = group.color, let tint = GroupTint(wire: color) { made.tint = tint }
        return made
    }
}

extension SidebarModel {
    /// A document item the list draws as a row (a link in a machine list), as a layout item a click runs.
    public func listedItem(_ id: LayoutItemID) -> LayoutItem? {
        for section in sections {
            for case .item(let item) in section.nodes where item.id == id.rawValue {
                return LayoutItem(id: id, ref: item.ref, label: item.title)
            }
        }
        return nil
    }
}
