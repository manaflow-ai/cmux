import Foundation
import Observation

/// The catalog's single owner of this Mac's Cloud sidebar organization.
/// It persists preferences, never resources, memberships, or running sessions.
@MainActor
@Observable
final class CloudSidebarOrganizationStore {
    private(set) var state: CloudSidebarOrganizationState
    @ObservationIgnored private let defaults: UserDefaults?
    private let key = "cloudTree.organization.v1"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        state = defaults?.data(forKey: key).flatMap {
            try? JSONDecoder().decode(CloudSidebarOrganizationState.self, from: $0)
        } ?? CloudSidebarOrganizationState()
    }

    @discardableResult
    func perform(_ action: CloudSidebarOrganizationAction, id: String, nodes: [CloudTreeNode]) -> Bool {
        guard let parent = CloudSidebarOrganizationTree(nodes: nodes).parent(of: id) else { return false }
        let siblings = parent.children.filter(\.canOrganize).map(\.id)
        var next = state
        guard next.apply(action, id: id, siblings: siblings, parent: parent.id) else { return false }
        commit(next)
        return true
    }

    /// Raise only containing workspace folders below the pins. Terminal rows and
    /// pinned folders retain their chosen order, matching the left sidebar. Called only by the admitted notification effect, never by
    /// an unread-set refresh, so reconnect and clear cannot replay a move.
    func raiseNotification(resource: SurfaceResourceID, nodes: [CloudTreeNode]) {
        raiseNotifications(resources: [resource], nodes: nodes)
    }

    func raiseNotifications(resources: [SurfaceResourceID], nodes: [CloudTreeNode]) {
        var siblings: [String: [String]] = [:]
        var placements: [SurfaceResourceID: [String: Set<String>]] = [:]
        func visit(_ parent: CloudTreeNode) -> Set<SurfaceResourceID> {
            var descendants = Set<SurfaceResourceID>()
            siblings[parent.id] = parent.children.filter(\.canOrganize).map(\.id)
            for child in parent.children {
                let resources: Set<SurfaceResourceID>
                if let resource = child.dragResource, resource.kind == .terminal { resources = [resource.id] }
                else { resources = visit(child) }
                descendants.formUnion(resources)
                if case .workspace = child.kind {
                    for resource in resources { placements[resource, default: [:]][parent.id, default: []].insert(child.id) }
                }
            }
            return descendants
        }
        for node in nodes { _ = visit(node) }
        var next = state
        for resource in resources where !resource.machine.isLocal {
            for (parent, matching) in placements[resource] ?? [:] {
                let ids = siblings[parent] ?? []
                // Reverse application raises matching siblings as one stable block.
                for id in next.ordered(ids, parent: parent).reversed()
                    where matching.contains(id) && !next.isPinned(id, parent: parent) {
                    _ = next.apply(.top, id: id, siblings: ids, parent: parent)
                }
            }
        }
        if next != state { commit(next) }
    }

    /// Prune only against a current accepted daemon graph, never a disconnect
    /// placeholder. Hidden-but-existing folders retain their child preferences.
    func reconcile(nodes: [CloudTreeNode], machine: SurfaceMachineID, workspaceIDs: Set<String>) {
        let folderIDs = Set(workspaceIDs.map { CloudTreeNodeBuilder.nodeID(workspace: $0, machine: machine) })
        let current = CloudTreeNodeBuilder.flattened(nodes).filter { $0.machine == machine }
        var live = Dictionary(current.map { ($0.id, Set($0.children.filter(\.canOrganize).map(\.id))) }, uniquingKeysWith: { first, _ in first })
        live[CloudTreeNodeBuilder.nodeID(workspacesGroup: machine)] = folderIDs
        let prefix = CloudTreeNodeBuilder.nodeID(machine: machine) + "/"
        var next = state
        for parent in Array(next.groups.keys) where parent.hasPrefix(prefix) {
            if let ids = live[parent], var group = next.groups[parent] {
                group.order.removeAll { !ids.contains($0) }
                group.pinned.formIntersection(ids)
                next.groups[parent] = group.order.isEmpty ? nil : group
            } else if !folderIDs.contains(parent) {
                next.groups[parent] = nil
            }
        }
        if next != state { commit(next) }
    }

    /// Confirmed machine deletion removes its saved rows. Connection/account
    /// teardown must not use this path because the same machine may return.
    func forget(machine: SurfaceMachineID) {
        let prefix = CloudTreeNodeBuilder.nodeID(machine: machine) + "/"
        var next = state
        next.groups = next.groups.filter { !$0.key.hasPrefix(prefix) }
        if next != state { commit(next) }
    }

    private func commit(_ next: CloudSidebarOrganizationState) {
        state = next
        if let defaults, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }
}
