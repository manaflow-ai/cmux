import CmuxCloud
import AppKit

extension CloudTreeOutlineView.Coordinator {
    var organizationNodes: [CloudTreeNode] { deferredNodes ?? nodes }

    func organizationMenuItems(for node: CloudTreeNode) -> [NSMenuItem] {
        guard node.canOrganize,
              let parent = CloudSidebarOrganizationTree(nodes: organizationNodes).parent(of: node.id) else { return [] }
        let state = organization.state
        let pinned = state.isPinned(node.id, parent: parent.id)
        let peers = state.ordered(parent.children.filter(\.canOrganize).map(\.id), parent: parent.id)
            .filter { state.isPinned($0, parent: parent.id) == pinned }
        let index = peers.firstIndex(of: node.id)
        func item(_ title: String, _ action: CloudSidebarOrganizationAction, enabled: Bool = true) -> NSMenuItem {
            let item = CloudTreeMenuItem(title: title) { [weak self] in
                self?.organize(action, nodeID: node.id)
            }
            item.isEnabled = enabled
            return item
        }
        return [
            item(pinned ? String(localized: "cloudTree.menu.unpin", defaultValue: "Unpin")
                        : String(localized: "cloudTree.menu.pin", defaultValue: "Pin"), pinned ? .unpin : .pin),
            item(String(localized: "contextMenu.moveUp", defaultValue: "Move Up"), .up, enabled: index.map { $0 > 0 } ?? false),
            item(String(localized: "contextMenu.moveDown", defaultValue: "Move Down"), .down, enabled: index.map { $0 + 1 < peers.count } ?? false),
            .separator()
        ]
    }

    @discardableResult
    func organize(_ action: CloudSidebarOrganizationAction, nodeID: String) -> Bool {
        let current = organizationNodes
        guard nodeActions.organize(action, nodeID, current) else { return false }
        // The catalog mutation is local and already authoritative for this
        // action. Do not wait for the native source's later `endedAt` callback
        // before reflecting the accepted reorder in the outline.
        applyOrganization(nodes: current)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // The tree is a navigation/source surface. Pane destinations own the
        // ownership warning and announcement; the tree draws no drag hints.
        guard ownershipRejection(info: info, item: item) == nil else {
            if let cloudOutline = outlineView as? CloudTreeNSOutlineView {
                cloudOutline.clearDragDestination(sequence: info.draggingSequenceNumber)
                cloudOutline.reorderPresentation.clear(sequence: info.draggingSequenceNumber)
            }
            return []
        }
        guard let drop = organizationDrop(outlineView, info: info, item: item, index: index) else {
            if let cloudOutline = outlineView as? CloudTreeNSOutlineView {
                cloudOutline.clearDragDestination(sequence: info.draggingSequenceNumber)
                cloudOutline.reorderPresentation.clear(sequence: info.draggingSequenceNumber)
            }
            return []
        }
        outlineView.setDropItem(drop.parent, dropChildIndex: drop.childIndex)
        if let cloudOutline = outlineView as? CloudTreeNSOutlineView {
            cloudOutline.trackDragDestination(sequenceNumber: info.draggingSequenceNumber)
            cloudOutline.reorderPresentation.show(drop, sequence: info.draggingSequenceNumber)
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        defer { (outlineView as? CloudTreeNSOutlineView)?.clearDragDestination(sequence: info.draggingSequenceNumber) }
        guard ownershipRejection(info: info, item: item) == nil else { return false }
        guard let drop = organizationDrop(outlineView, info: info, item: item, index: index) else { return false }
        switch drop.operation {
        case .organization(let action):
            return organize(action, nodeID: drop.sourceID)
        case .machine(let id, let move):
            guard let actions = machineOrdering(for: info, nodeID: drop.sourceID) else { return false }
            return moveMachine(id, move: move, using: actions)
        }
    }

    /// Keeps the shared ownership boundary ahead of sidebar organization mutations.
    private func ownershipRejection(info: any NSDraggingInfo, item: Any?) -> SurfaceTransferRejection? {
        guard let node = item as? CloudTreeNode, !node.machine.isLocal,
              DragOverlayRoutingPolicy.hasBonsplitTabTransfer(info.draggingPasteboard.types) else { return nil }
        let resolver = PaneTransferSourceResolver()
        let policy = SurfaceOwnershipPolicy(cloudMachine: node.machine)
        guard let transfer = resolver.transfer(from: info.draggingPasteboard),
              let source = resolver.source(for: transfer) else { return policy.rejection(for: nil) }
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: policy)
        case .surface:
            guard let app = AppDelegate.shared else { return policy.rejection(for: nil) }
            return app.ownershipRejection(forBonsplitTab: transfer.tabId, policy: policy)
        case .vaultSession, .filePreview, .rightSidebarTool:
            return policy.rejection(for: .local)
        }
    }

    /// Internal moves never cross a parent or pin partition. In particular, a
    /// folder drag must not become a remote tab.move and detach a running pane.
    /// Projection-capable leaves also reorder here; their export capability is
    /// consumed only by pane destinations, never by this organization action.
    private func organizationDrop(_ outlineView: NSOutlineView, info: any NSDraggingInfo,
                                  item: Any?, index: Int) -> CloudSidebarOrganizationDrop? {
        guard let source = info.draggingSource as? NSOutlineView, source === outlineView,
              let id = info.draggingPasteboard.string(forType: .cloudSidebarRow) else { return nil }
        let row = item.map { outlineView.row(forItem: $0) } ?? -1
        let point = outlineView.convert(info.draggingLocation, from: nil)
        // Native indices refer to the frozen, displayed tree. Fresh catalog
        // membership is checked by organize, never substituted into this index.
        guard let drop = CloudSidebarOrganizationDrop(
            sourceID: id, nodes: nodes, state: organization.state,
            proposedItem: item as? CloudTreeNode, proposedChildIndex: index,
            dropAfterItem: row >= 0 && point.y >= outlineView.rect(ofRow: row).midY
        ) else { return nil }
        if case .machine(let machineID, let move) = drop.operation {
            guard machineOrdering(for: info, nodeID: id)?.canMove(machineID, move) == true else { return nil }
        }
        return drop
    }
}
