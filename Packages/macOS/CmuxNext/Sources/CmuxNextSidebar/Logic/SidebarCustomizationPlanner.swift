import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// Applies the Rust sidebar customization plan to native rows. Rust decides
/// which rows survive, their order, and valid group targets; this type only
/// copies the returned ids into the existing document projection.
struct SidebarCustomizationPlanner {
    private struct Reply: Decodable {
        var sectionOrder: [String]
        var hiddenSections: [String]
        var hiddenWorkspaces: [String]
        var workspaceGroups: [String: String]
        var workspaceOrders: [String: Int]

        enum CodingKeys: String, CodingKey {
            case sectionOrder = "section_order"
            case hiddenSections = "hidden_sections"
            case hiddenWorkspaces = "hidden_workspaces"
            case workspaceGroups = "workspace_groups"
            case workspaceOrders = "workspace_orders"
        }
    }

    static func apply(_ sections: [SidebarSection], customization: SidebarProjectionCustomization,
                     selected: WorkspaceID?) -> [SidebarSection] {
        guard !customization.hiddenSections.isEmpty || !customization.sectionOrder.isEmpty || !customization.workspaces.isEmpty else {
            return sections
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
        guard let reply = RustSidebarClient.call("sidebar_section_customization", request, as: Reply.self) else { return sections }
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
        for workspaceID in reply.workspaceGroups.keys.sorted() {
            guard let targetID = reply.workspaceGroups[workspaceID],
                  let workspace = find(workspaceID, in: result),
                  result.indices.contains(workspace.section),
                  let target = result[workspace.section].nodes.firstIndex(where: { node in
                if case let .group(group) = node { return group.id.rawValue == targetID }
                return false
            }) else { continue }
            // Resolve the destination before removing the source. If a live
            // update changed the document between planning and projection,
            // the original row remains visible instead of being dropped.
            var candidate = result
            guard let moved = remove(workspaceID, from: &candidate, section: workspace.section) else { continue }
            guard let destination = candidate[workspace.section].nodes.firstIndex(where: { node in
                if case let .group(candidate) = node { return candidate.id.rawValue == targetID }
                return false
            }), case let .group(group) = candidate[workspace.section].nodes[destination] else { continue }
            var destinationGroup = group
            destinationGroup.workspaces.append(moved)
            candidate[workspace.section].nodes[destination] = .group(destinationGroup)
            result = candidate
        }

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
        return orderedSections + result.filter { seen.insert(Self.id($0)).inserted }
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

    private static func find(_ id: String, in sections: [SidebarSection]) -> (section: Int, node: Int)? {
        for (sectionIndex, section) in sections.enumerated() {
            for (nodeIndex, node) in section.nodes.enumerated() where node.workspaces.contains(where: { $0.id.rawValue == id }) {
                return (sectionIndex, nodeIndex)
            }
        }
        return nil
    }

    private static func remove(_ id: String, from sections: inout [SidebarSection], section sectionIndex: Int) -> SidebarWorkspace? {
        guard sections.indices.contains(sectionIndex) else { return nil }
        for nodeIndex in sections[sectionIndex].nodes.indices {
            switch sections[sectionIndex].nodes[nodeIndex] {
            case let .workspace(workspace) where workspace.id.rawValue == id:
                sections[sectionIndex].nodes.remove(at: nodeIndex); return workspace
            case var .group(group):
                if let index = group.workspaces.firstIndex(where: { $0.id.rawValue == id }) {
                    let workspace = group.workspaces.remove(at: index)
                    sections[sectionIndex].nodes[nodeIndex] = .group(group)
                    return workspace
                }
            default: break
            }
        }
        return nil
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
