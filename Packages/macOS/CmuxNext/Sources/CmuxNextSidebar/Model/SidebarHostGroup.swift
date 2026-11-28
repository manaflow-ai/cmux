public import CmuxNextDesign
import Foundation

/// How a remote group's header draws (user 2026-10-31, Chief msg 19277: "it needs to look like a group
/// in the sidebar"). Every look but ``sectionHeader`` draws the machine as one sidebar group: the
/// group's bar, chevron, rail and member rows, with the machine's mark on the bar.
public nonisolated enum SidebarHostGroupLook: String, CaseIterable, Sendable {
    /// Before: the machine's section header (quiet text, status dot and word), members unindented.
    case sectionHeader
    /// The group bar with a trailing machine mark and status dot, left of the chevron (the default).
    case trailingMarkAndDot
    /// The machine mark leads the name, as a group's icon does; the status dot trails.
    case leadingMark
    /// The status dot alone trails the name; no machine mark.
    case dotOnly
    /// The trailing machine mark and the status in words ("Connected", "Offline").
    case markAndWords
    /// The trailing machine mark alone while connected; the dot shows only when it needs attention.
    case markQuietWhenConnected
}

extension SidebarGroup {
    /// The group id a remote group of machine `machine` takes; never a document group's (those are UUIDs).
    public static func hostGroupID(_ machine: MachineID) -> GroupID { GroupID("host:" + machine.rawValue) }

    /// The machine a remote group id stands for (``hostGroupID(_:)``); nil for every other group.
    public static func hostMachine(_ id: GroupID) -> MachineID? {
        id.rawValue.hasPrefix("host:") ? MachineID(String(id.rawValue.dropFirst(5))) : nil
    }
}

extension SidebarSection {
    /// This remote group's section as one sidebar group: a header in the group look (the machine's name,
    /// its mark and status) over every row of the section, its loose workspaces as members and its
    /// groups nested one level down, so it folds, rails and indents as any group does.
    /// The section's own header is not drawn (``drawsAsGroup``); a section that is not a remote group
    /// comes back unchanged.
    public func wrappedAsHostGroup(look: SidebarHostGroupLook = .trailingMarkAndDot) -> SidebarSection {
        guard isHostGroup, case let .machine(machine) = kind, machine.kind != .local else { return self }
        let id = SidebarGroup.hostGroupID(machine.id)
        var host = SidebarGroup(id: id, name: machine.name, color: .grey, isCollapsed: isCollapsed, workspaces: [])
        host.tint = .none // nobody picked a color for a machine's group: none, not a grey band
        host.machine = machine
        host.hostLook = look
        var members: [SidebarGroupMember] = []
        var groups: [SidebarNode] = []
        for node in nodes {
            switch node {
            case let .workspace(ws): members.append(.workspace(ws))
            case let .item(item): members.append(.item(item))
            case var .group(group):
                if group.parent == nil { group.parent = id }
                group.depth += 1
                groups.append(.group(group))
            }
        }
        host.setMembers(members)
        var section = self
        section.nodes = [.group(host)] + groups
        // The group folds instead of the section: a folded section would hide its header too.
        section.isCollapsed = false
        section.drawsAsGroup = true
        return section
    }
}

extension SidebarSection {
    /// A wrapped remote group's section as the document lists it again (a fold passes the shown list back
    /// to `arrange`): its members loose, its groups at the top level; any other section unchanged.
    public func unwrappedHostGroup() -> SidebarSection {
        guard drawsAsGroup else { return self }
        var section = self
        section.nodes = []
        for node in nodes {
            guard case var .group(group) = node else { section.nodes.append(node); continue }
            if group.machine != nil {
                section.isCollapsed = group.isCollapsed
                for member in group.members {
                    switch member {
                    case let .workspace(ws): section.nodes.append(.workspace(ws))
                    case let .item(item): section.nodes.append(.item(item))
                    }
                }
                continue
            }
            if group.parent.flatMap(SidebarGroup.hostMachine) != nil { group.parent = nil }
            group.depth = max(0, group.depth - 1)
            section.nodes.append(.group(group))
        }
        section.drawsAsGroup = false
        return section
    }
}

extension SidebarIntent {
    /// This intent as the daemon takes it when it names a remote group (``SidebarGroup/hostGroupID(_:)``),
    /// which no document holds: a fold folds the machine's section, + makes a workspace on the machine,
    /// a drop into it lands at the section's top level. Group edits that have no machine meaning
    /// (rename, color, ungroup, pin, icon, close, reorder) are dropped (nil). Other intents come back as is.
    /// `end` counts a machine section's top-level rows as the document holds them (a drop's last slot).
    public func resolvingHostGroup(end: (MachineID) -> Int) -> SidebarIntent? {
        typealias Op = RustSidebarDocTarget
        // The op's intent (`sidebar_doc_target` op `resolving_host_group`); an intent it only passes back comes back as is.
        var ends: [String: Int] = [:]
        let intent: Op.Intent
        switch self {
        case let .toggleCollapse(.group(id)):
            intent = Op.Intent(kind: "toggle_collapse_group", group: id.rawValue)
        case let .newWorkspace(machine, group):
            intent = Op.Intent(kind: "new_workspace", group: group?.rawValue, machine: machine?.rawValue)
        case let .move(ids, toGroup: id):
            if let machine = SidebarGroup.hostMachine(id) { ends[machine.rawValue] = end(machine) }
            intent = Op.Intent(kind: "move", group: id.rawValue, ids: ids.map(\.rawValue))
        case let .reorder(ids, to: position):
            intent = Op.Intent(kind: "reorder", ids: ids.map(\.rawValue),
                               to: Op.Intent.Position(section: nil, group: position.group?.rawValue, index: position.index))
        case let .renameGroup(id, _), let .groupEditorEnded(id), let .setGroupColor(id, _), let .ungroup(id),
             let .setGroupPinned(id, _), let .setGroupIcon(id, _), let .closeGroup(id), let .openGroup(id),
             let .reorderGroup(id, _):
            intent = Op.Intent(kind: "group_edit", group: id.rawValue)
        default:
            return self
        }
        // When the op does not answer, the intent as is (the daemon refuses a remote group's id).
        guard let reply = RustSidebarClient.call(Op.op, Op.ResolvingRequest(intent: intent, ends: ends), as: Op.ResolvingReply.self)
        else { return self }
        guard let resolved = reply.intent else { return nil }
        switch resolved.kind {
        case "toggle_collapse_section":
            guard let machine = resolved.section?.machine else { return self }
            return .toggleCollapse(.section(.machine(MachineID(machine))))
        case "new_workspace":
            return .newWorkspace(machine: resolved.machine.map(MachineID.init), group: resolved.group.map(GroupID.init))
        case "reorder":
            guard let to = resolved.to else { return self }
            let ids = (resolved.ids ?? []).map(WorkspaceID.init)
            // A move into a remote group names its machine's section; a reorder keeps its own.
            let section: SectionID = if let machine = to.section?.machine { .machine(MachineID(machine)) }
                else if case let .reorder(_, position) = self { position.section } else { .machine(.local) }
            return .reorder(ids, to: DropPosition(section: section, group: to.group.map(GroupID.init), index: to.index))
        default:
            return self
        }
    }
}

extension SidebarSection {
    /// A wrapped remote group's top-level rows as the document holds them: its loose members and its groups.
    var documentNodeCount: Int {
        typealias Op = RustSidebarDocTarget
        let nodes: [Op.NodeCountRequest.Node] = self.nodes.map { node in
            guard case let .group(group) = node else { return .row }
            return .group(host: group.machine != nil, parent: group.parent?.rawValue, members: group.members.count)
        }
        // `sidebar_doc_target` op `document_node_count`; when it does not answer, every node counts.
        return RustSidebarClient.call(Op.op, Op.NodeCountRequest(draws_as_group: drawsAsGroup, nodes: nodes), as: Op.NodeCountReply.self)?.count
            ?? nodes.count
    }
}
