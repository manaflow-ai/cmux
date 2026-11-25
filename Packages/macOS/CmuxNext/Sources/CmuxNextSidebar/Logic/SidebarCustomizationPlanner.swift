import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// Applies the Rust sidebar customization plan to native rows. Rust decides
/// which rows survive, their order, and valid group targets; this type only
/// copies the returned ids into the existing document projection.
struct SidebarCustomizationPlanner {
    struct Reply: Decodable {
        var sectionOrder: [String]
        var hiddenSections: [String]
        var hiddenWorkspaces: [String]
        var workspaceGroups: [String: String]
        var workspaceOrders: [String: Int]
        var selectionSpared: Bool

        enum CodingKeys: String, CodingKey {
            case sectionOrder = "section_order"
            case hiddenSections = "hidden_sections"
            case hiddenWorkspaces = "hidden_workspaces"
            case workspaceGroups = "workspace_groups"
            case workspaceOrders = "workspace_orders"
            case selectionSpared = "selection_spared"
        }

        /// The linked FFI is a pin (`app-ffi-pin.json`) that can predate this Swift: a field Rust added later is
        /// optional here, or every reply from the older pin fails to decode and no setting applies. A reply with no
        /// `selection_spared` says nothing about the selection, so the next selection change projects again.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sectionOrder = try values.decode([String].self, forKey: .sectionOrder)
            hiddenSections = try values.decode([String].self, forKey: .hiddenSections)
            hiddenWorkspaces = try values.decode([String].self, forKey: .hiddenWorkspaces)
            workspaceGroups = try values.decode([String: String].self, forKey: .workspaceGroups)
            workspaceOrders = try values.decode([String: Int].self, forKey: .workspaceOrders)
            selectionSpared = try values.decodeIfPresent(Bool.self, forKey: .selectionSpared) ?? true
        }
    }

    /// The customized rows, and whether the settings hide the selected workspace or its section and only the
    /// selection keeps it shown (Rust's `selection_spared`): then the next selection change projects again, and a
    /// selection change that is not one of these needs no projection (`SidebarModel.selectionReprojects`).
    struct Projection {
        var sections: [SidebarSection]
        var selectionSpared = false
    }

    static func apply(_ sections: [SidebarSection], customization: SidebarProjectionCustomization,
                      selected: WorkspaceID?) -> Projection {
        guard !customization.hiddenSections.isEmpty || !customization.sectionOrder.isEmpty || !customization.workspaces.isEmpty else {
            return Projection(sections: sections)
        }
        let request = JSONValue.object([
            "sections": .object(["hidden": .array(customization.hiddenSections.map(JSONValue.string)),
                                  "order": .array(customization.sectionOrder.map(JSONValue.string))]),
            "workspaces": .object(customization.workspaces.mapValues { value in
                .object(["hidden": .bool(value.hidden), "group": value.group.map(JSONValue.string) ?? .null,
                         "order": value.order.map { .number(Double($0)) } ?? .null])
            }),
            "input": .array(sections.map(input)),
            "selected": selected.map { .string($0.rawValue) } ?? .null,
        ])
        guard let reply = RustSidebarClient.call("sidebar_section_customization", request, as: Reply.self) else {
            return Projection(sections: sections)
        }
        let hiddenSections = Set(reply.hiddenSections)
        var result = sections.filter { !hiddenSections.contains(Self.id($0)) }
        let hiddenWorkspaces = Set(reply.hiddenWorkspaces.map(WorkspaceID.init))
        result = result.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return hiddenWorkspaces.contains(workspace.id) ? nil : node
                case .group(var group):
                    group.workspaces.removeAll { hiddenWorkspaces.contains($0.id) }
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }

        // Group moves are valid only within their original section; the Rust
        // planner has already rejected unknown groups and cross-section moves.
        if !reply.workspaceGroups.isEmpty { moveIntoGroups(&result, reply.workspaceGroups) }

        for sectionIndex in result.indices {
            var section = result[sectionIndex]
            var workspaceIndices: [Int] = []
            var loose: [SidebarWorkspace] = []
            for (index, node) in section.nodes.enumerated() {
                if case let .workspace(workspace) = node, reply.workspaceOrders[workspace.id.rawValue] != nil {
                    workspaceIndices.append(index)
                    loose.append(workspace)
                }
            }
            let orderedLoose = ordered(loose, by: reply.workspaceOrders)
            for (index, workspace) in zip(workspaceIndices, orderedLoose) { section.nodes[index] = .workspace(workspace) }
            section.nodes = section.nodes.map { node in
                guard case var .group(group) = node else { return node }
                group.workspaces = ordered(group.workspaces, by: reply.workspaceOrders)
                return .group(group)
            }
            result[sectionIndex] = section
        }

        let byID = Dictionary(result.map { (Self.id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let orderedSections = reply.sectionOrder.compactMap { id -> SidebarSection? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return Projection(sections: orderedSections + result.filter { seen.insert(Self.id($0)).inserted },
                          selectionSpared: reply.selectionSpared)
    }

    /// Moves each workspace in `moves` (workspace id to group id) out of its node to the end of its target group, in
    /// the section that first lists it and in workspace-id order; a target this section lacks (a live update changed
    /// the document after planning) leaves the row where it is. One pass over each section's rows: a move used to
    /// search every section and copy the projection, so a regroup rule for every workspace cost the square of the
    /// sidebar.
    private static func moveIntoGroups(_ sections: inout [SidebarSection], _ moves: [String: String]) {
        var listed = Set<String>() // a workspace's first listing decides its section
        for sectionIndex in sections.indices {
            var groupNodes: [String: Int] = [:]
            for (index, node) in sections[sectionIndex].nodes.enumerated() {
                if case let .group(group) = node, groupNodes[group.id.rawValue] == nil { groupNodes[group.id.rawValue] = index }
            }
            var arriving: [Int: [SidebarWorkspace]] = [:]
            func leaves(_ workspace: SidebarWorkspace) -> Bool {
                let id = workspace.id.rawValue
                guard listed.insert(id).inserted, let target = moves[id].flatMap({ groupNodes[$0] }) else { return false }
                arriving[target, default: []].append(workspace)
                return true
            }
            var nodes: [SidebarNode?] = sections[sectionIndex].nodes.map { node in
                switch node {
                case let .workspace(workspace):
                    return leaves(workspace) ? nil : node
                case var .group(group):
                    let count = group.workspaces.count
                    group.workspaces.removeAll(where: leaves)
                    return group.workspaces.count == count ? node : .group(group)
                case .item:
                    return node
                }
            }
            guard !arriving.isEmpty else { continue }
            for (target, workspaces) in arriving {
                guard case var .group(group)? = nodes[target] else { continue }
                group.workspaces += workspaces.sorted { $0.id.rawValue < $1.id.rawValue }
                nodes[target] = .group(group)
            }
            sections[sectionIndex].nodes = nodes.compactMap { $0 }
        }
    }

    private static func input(_ section: SidebarSection) -> JSONValue {
        let keys: [String] = switch section.kind {
        case .pinned: ["pinned", "sec_pinned"]
        case let .machine(machine): [machine.id.rawValue, "machine:\(machine.id.rawValue)", "projects"]
        case let .custom(custom):
            [custom.id] + (custom.id == "sec_workspaces" ? ["projects"] : [])
        }
        let nodes = section.nodes.map { node -> JSONValue in
            switch node {
            case let .workspace(workspace):
                return .object(["id": .string(workspace.id.rawValue), "kind": .string("workspace"), "workspace_ids": .array([.string(workspace.id.rawValue)])])
            case let .group(group):
                return .object(["id": .string(group.id.rawValue), "kind": .string("group"), "name": .string(group.name),
                                 "workspace_ids": .array(group.workspaces.map { .string($0.id.rawValue) })])
            case let .item(item):
                return .object(["id": .string(item.id), "kind": .string("item")])
            }
        }
        let region: String = switch section.kind {
        case .pinned: "top"
        case .machine: "middle"
        case let .custom(custom): custom.region.rawValue
        }
        return .object(["id": .string(Self.id(section)), "keys": .array(keys.map(JSONValue.string)), "region": .string(region), "nodes": .array(nodes)])
    }

    private static func ordered(_ workspaces: [SidebarWorkspace], by orders: [String: Int]) -> [SidebarWorkspace] {
        let ranked = workspaces.indices.filter { orders[workspaces[$0].id.rawValue] != nil }
        guard ranked.count > 1 else { return workspaces }
        let sorted = ranked.map { workspaces[$0] }.sorted {
            let lhs = orders[$0.id.rawValue] ?? Int.max
            let rhs = orders[$1.id.rawValue] ?? Int.max
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
        }
        var result = workspaces
        for (index, workspace) in zip(ranked, sorted) { result[index] = workspace }
        return result
    }

    private static func id(_ section: SidebarSection) -> String {
        switch section.kind {
        case .pinned: "sec_pinned"
        case let .machine(machine): "sec_m_\(machine.id.rawValue)"
        case let .custom(custom): custom.id
        }
    }
}
