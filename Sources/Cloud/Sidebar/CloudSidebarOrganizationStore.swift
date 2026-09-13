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

    /// Move every placement of this terminal and its folder within their current
    /// pin partition. Called only by the admitted notification effect, never by
    /// an unread-set refresh, so reconnect and clear cannot replay a move.
    func raiseNotification(resource: SurfaceResourceID, nodes: [CloudTreeNode]) {
        guard !resource.machine.isLocal else { return }
        var next = state
        func visit(_ parent: CloudTreeNode) -> Bool {
            var containsTerminal = false
            for child in parent.children {
                let matches = child.dragResource?.id == resource || visit(child)
                if matches {
                    containsTerminal = true
                    if child.canOrganize {
                        _ = next.apply(.top, id: child.id,
                                       siblings: parent.children.filter(\.canOrganize).map(\.id), parent: parent.id)
                    }
                }
            }
            return containsTerminal
        }
        for node in nodes where node.machine == resource.machine { _ = visit(node) }
        if next != state { commit(next) }
    }

    private func commit(_ next: CloudSidebarOrganizationState) {
        state = next
        if let defaults, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }
}
