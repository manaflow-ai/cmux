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
        apply(nodes: current)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let drop = organizationDrop(outlineView, info: info, item: item, index: index) else { return [] }
        outlineView.setDropItem(drop.parent, dropChildIndex: drop.childIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let drop = organizationDrop(outlineView, info: info, item: item, index: index) else { return false }
        return organize(drop.action, nodeID: drop.sourceID)
    }

    /// Internal moves never cross a parent or pin partition. In particular, a
    /// folder drag must not become a remote tab.move and detach a running pane.
    private func organizationDrop(_ outlineView: NSOutlineView, info: any NSDraggingInfo,
                                  item: Any?, index: Int) -> CloudSidebarOrganizationDrop? {
        guard let source = info.draggingSource as? NSOutlineView, source === outlineView,
              let id = info.draggingPasteboard.string(forType: .cloudSidebarRow) else { return nil }
        let row = item.map { outlineView.row(forItem: $0) } ?? -1
        let point = outlineView.convert(info.draggingLocation, from: nil)
        // Native indices refer to the frozen, displayed tree. Fresh catalog
        // membership is checked by organize, never substituted into this index.
        return CloudSidebarOrganizationDrop(
            sourceID: id, nodes: nodes, state: organization.state,
            proposedItem: item as? CloudTreeNode, proposedChildIndex: index,
            dropAfterItem: row >= 0 && point.y >= outlineView.rect(ofRow: row).midY
        )
    }
}
