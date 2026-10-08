import AppKit
import CmuxSurfaceCatalogModel

/// Starts a scan for expanded Cloud machines in the outline viewport.
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
        // A snapshot can be applied before AppKit has performed the containing
        // view's first layout pass. Materialize row geometry before checking
        // the visibility boundary so an already visible machine is not missed.
        outline.layoutSubtreeIfNeeded()
        for root in candidates where !requested.contains(root.machine) {
            // A collapsed machine has a visible title row but no visible Ports
            // summary. Keep its scan lazy until the machine is expanded. Rows
            // outside the viewport are likewise deferred until scrolling brings
            // them on screen.
            let row = outline.row(forItem: root)
            guard outline.isItemExpanded(root),
                  row >= 0,
                  outline.rect(ofRow: row).intersects(outline.visibleRect) else { continue }
            requested.insert(root.machine)
            coordinator.nodeActions.discoverPorts(root.machine)
        }
    }

    deinit { scheduled?.cancel() }
}
