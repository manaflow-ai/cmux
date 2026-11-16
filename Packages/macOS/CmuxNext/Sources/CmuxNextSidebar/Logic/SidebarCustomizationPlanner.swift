import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// What the last projection decided beyond the rows themselves: whether it
/// kept a hidden row or section drawn only because it holds the selection,
/// its stable revision, and every hide the settings make that a Show control
/// can undo.
public nonisolated struct SidebarProjectionPlan: Hashable, Sendable {
    public struct Restorable: Hashable, Sendable, Decodable {
        /// `section` or `workspace`.
        public var kind: String
        public var id: String
        /// The settings value a Show clears (the hidden entry as written).
        public var key: String
    }

    public var revision: UInt64 = 0
    public var selectionOverridesHide = false
    public var restorable: [Restorable] = []
    public static let none = Self()
}

/// Applies the Rust sidebar customization plan to native rows. Rust decides
/// which rows survive, their order, and valid group targets; this type only
/// copies the returned ids into the existing document projection.
///
/// The request is the document's outline (sections and their groups) plus
/// the location of only the workspaces the settings name and the selected
/// one, so its size and the Rust work are the same at 30 and 3,000 rows.
struct SidebarCustomizationPlanner {
    private struct Reply: Decodable {
        var sectionOrder: [String]
        var hiddenSections: [String]
        var hiddenWorkspaces: [String]
        var workspaceGroups: [String: String]
        var workspaceOrders: [String: Int]
        var restorable: [SidebarProjectionPlan.Restorable]
        var selectionOverridesHide: Bool
        var revision: UInt64

        enum CodingKeys: String, CodingKey {
            case sectionOrder = "section_order"
            case hiddenSections = "hidden_sections"
            case hiddenWorkspaces = "hidden_workspaces"
            case workspaceGroups = "workspace_groups"
            case workspaceOrders = "workspace_orders"
            case restorable
            case selectionOverridesHide = "selection_overrides_hide"
            case revision
        }
    }

    static func apply(_ sections: [SidebarSection], customization: SidebarProjectionCustomization,
                      selected: WorkspaceID?) -> [SidebarSection] {
        plan(sections, customization: customization, selected: selected).sections
    }

    /// The projected sections and what the plan decided.
    static func plan(_ sections: [SidebarSection], customization: SidebarProjectionCustomization,
                     selected: WorkspaceID?) -> (sections: [SidebarSection], plan: SidebarProjectionPlan) {
        guard !customization.hiddenSections.isEmpty || !customization.sectionOrder.isEmpty || !customization.workspaces.isEmpty else {
            return (sections, .none)
        }
        var named = Set(customization.workspaces.keys)
        if let selected { named.insert(selected.rawValue) }
        let request = JSONValue.object([
            "sections": .object(["hidden": .array(customization.hiddenSections.map(JSONValue.string)),
                                  "order": .array(customization.sectionOrder.map(JSONValue.string))]),
            "workspaces": .object(customization.workspaces.mapValues { value in
                .object(["hidden": .bool(value.hidden), "group": value.group.map(JSONValue.string) ?? .null,
                         "order": value.order.map { .number(Double($0)) } ?? .null])
            }),
            "outline": .array(sections.map(outline)),
            "locations": .object(locations(of: named, in: sections)),
            "selected": selected.map { .string($0.rawValue) } ?? .null,
        ])
        guard let reply = RustSidebarClient.call("sidebar_section_customization", request, as: Reply.self) else {
            return (sections, .none)
        }
        let plan = SidebarProjectionPlan(revision: reply.revision, selectionOverridesHide: reply.selectionOverridesHide,
                                         restorable: reply.restorable)
        let hiddenSections = Set(reply.hiddenSections)
        var result = hiddenSections.isEmpty ? sections : sections.filter { !hiddenSections.contains(Self.id($0)) }
        let hiddenWorkspaces = Set(reply.hiddenWorkspaces.map(WorkspaceID.init))
        if !hiddenWorkspaces.isEmpty {
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
        }

        // Group moves are valid only within their original section; the Rust
        // planner has already rejected unknown groups and cross-section moves.
        for workspaceID in reply.workspaceGroups.keys.sorted() {
            guard let targetID = reply.workspaceGroups[workspaceID],
                  let workspace = find(workspaceID, in: result),
                  result.indices.contains(workspace.section),
                  result[workspace.section].nodes.contains(where: { node in
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

        // An explicit order ranks only the rows it names, in their own list,
        // without rewriting the document's stored order.
        if !reply.workspaceOrders.isEmpty {
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
        }

        let byID = Dictionary(result.map { (Self.id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let orderedSections = reply.sectionOrder.compactMap { id -> SidebarSection? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return (orderedSections + result.filter { seen.insert(Self.id($0)).inserted }, plan)
    }

    /// One section's outline: its id, the keys settings may name it by, its
    /// region and its groups. Loose rows and group members are not listed.
    private static func outline(_ section: SidebarSection) -> JSONValue {
        let keys: [String] = switch section.kind {
        case .pinned: ["pinned", "sec_pinned"]
        case let .machine(machine): [machine.id.rawValue, "machine:\(machine.id.rawValue)", "projects"]
        case let .custom(custom):
            [custom.id] + (custom.id == "sec_workspaces" ? ["projects"] : [])
        }
        let groups = section.nodes.compactMap { node -> JSONValue? in
            guard case let .group(group) = node else { return nil }
            return .object(["id": .string(group.id.rawValue), "name": .string(group.name)])
        }
        let region: String = switch section.kind {
        case .pinned: "top"
        case .machine: "middle"
        case let .custom(custom): custom.region.rawValue
        }
        return .object(["id": .string(Self.id(section)), "keys": .array(keys.map(JSONValue.string)), "region": .string(region),
                        "groups": .array(groups)])
    }

    /// Where each of `ids` first lists: its section and, for a group member,
    /// its group. One pass that stops once every id is found; a row the
    /// settings do not name is never encoded.
    static func locations(of ids: Set<String>, in sections: [SidebarSection]) -> [String: JSONValue] {
        var found: [String: JSONValue] = [:]
        guard !ids.isEmpty else { return found }
        for section in sections {
            let sectionID = JSONValue.string(Self.id(section))
            for node in section.nodes {
                switch node {
                case let .workspace(workspace):
                    let id = workspace.id.rawValue
                    if ids.contains(id), found[id] == nil { found[id] = .object(["section": sectionID]) }
                case let .group(group):
                    for member in group.workspaces {
                        let id = member.id.rawValue
                        if ids.contains(id), found[id] == nil {
                            found[id] = .object(["section": sectionID, "group": .string(group.id.rawValue)])
                        }
                    }
                case .item:
                    break
                }
                if found.count == ids.count { return found }
            }
        }
        return found
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
