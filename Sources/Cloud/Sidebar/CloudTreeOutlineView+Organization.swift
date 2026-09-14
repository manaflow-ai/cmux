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
        dropAction(outlineView, info: info, parent: item, index: index) == nil ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let (id, action) = dropAction(outlineView, info: info, parent: item, index: index) else { return false }
        return organize(action, nodeID: id)
    }

    /// Internal moves never cross a parent or pin partition. In particular, a
    /// folder drag must not become a remote tab.move and detach a running pane.
    private func dropAction(_ outlineView: NSOutlineView, info: any NSDraggingInfo,
                            parent: Any?, index: Int) -> (String, CloudSidebarOrganizationAction)? {
        guard let source = info.draggingSource as? NSOutlineView, source === outlineView,
              let id = info.draggingPasteboard.string(forType: .cloudSidebarRow),
              let parent = parent as? CloudTreeNode, index >= 0, index <= parent.children.count,
              CloudSidebarOrganizationTree(nodes: organizationNodes).parent(of: id)?.id == parent.id else { return nil }
        let pinned = organization.state.isPinned(id, parent: parent.id)
        let before = parent.children.prefix(index).last { $0.canOrganize && $0.id != id }
        let after = parent.children.dropFirst(index).first { $0.canOrganize && $0.id != id }
        if let after, organization.state.isPinned(after.id, parent: parent.id) == pinned {
            return (id, .before(after.id))
        }
        if let before, organization.state.isPinned(before.id, parent: parent.id) == pinned {
            return (id, .after(before.id))
        }
        return nil
    }
}
