import AppKit

/// Starts a scan only for an expanded, visible Ports group, including restored/default expansion.
@MainActor
final class CloudPortsDiscoveryDemand {
    private var scheduled: Task<Void, Never>?
    private var candidates: [CloudTreeNode] = []
    private var requested: Set<SurfaceMachineID> = []

    func update(nodes: [CloudTreeNode]) {
        candidates = CloudTreeNodeBuilder.flattened(nodes).filter { node in
            guard case .machine(_, let info) = node.kind else { return false }
            return info?.portDiscoveryState == .notRequested
        }
        requested.formIntersection(candidates.map(\.machine))
    }

    func schedule(coordinator: CloudTreeOutlineView.Coordinator) {
        guard scheduled == nil, candidates.contains(where: { !requested.contains($0.machine) }) else { return }
        scheduled = Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator, !Task.isCancelled else { return }
            defer { self.scheduled = nil }
            self.reconcile(coordinator: coordinator)
        }
    }

    func reconcile(coordinator: CloudTreeOutlineView.Coordinator) {
        guard let outline = coordinator.outlineView, outline.window != nil else { return }
        for root in candidates where !requested.contains(root.machine) {
            guard outline.row(forItem: root) >= 0, outline.isItemExpanded(root),
                  let ports = root.children.first(where: { if case .portsGroup = $0.kind { true } else { false } }),
                  outline.isItemExpanded(ports) else { continue }
            requested.insert(root.machine)
            coordinator.nodeActions.discoverPorts(root.machine)
        }
    }

    deinit { scheduled?.cancel() }
}
