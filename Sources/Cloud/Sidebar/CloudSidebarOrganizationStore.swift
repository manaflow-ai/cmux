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

    /// Raise unpinned placements and folders below the pins. Pinned rows retain
    /// their chosen order, matching the left sidebar. Called only by the admitted notification effect, never by
    /// an unread-set refresh, so reconnect and clear cannot replay a move.
    func raiseNotification(resource: SurfaceResourceID, nodes: [CloudTreeNode]) {
        guard !resource.machine.isLocal else { return }
        var next = state
        func visit(_ parent: CloudTreeNode) -> Bool {
            let matching = Set(parent.children.filter { child in
                child.dragResource?.id == resource || visit(child)
            }.map(\.id))
            let siblings = parent.children.filter(\.canOrganize).map(\.id)
            // Lifting several views of one terminal must retain their relative
            // order; repeated notifications must never flip the same folders.
            for id in next.ordered(siblings, parent: parent.id).reversed()
                where matching.contains(id) && !next.isPinned(id, parent: parent.id) {
                _ = next.apply(.top, id: id, siblings: siblings, parent: parent.id)
            }
            return !matching.isEmpty
        }
        for node in nodes where node.machine == resource.machine { _ = visit(node) }
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

    private func commit(_ next: CloudSidebarOrganizationState) {
        state = next
        if let defaults, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }
}
