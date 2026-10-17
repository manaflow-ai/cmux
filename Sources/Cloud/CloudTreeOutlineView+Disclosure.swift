import AppKit

extension CloudTreeOutlineView.Coordinator {
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isUpdatingProgrammatically,
              let node = notification.userInfo?["NSObject"] as? CloudTreeNode,
              let outline = notification.object as? CloudTreeNSOutlineView,
              outline.disclosureScope.records(node, in: outline) else { return }
        expansionStore.setExpanded(true, node: node)
        if node.kind.refreshesOnExpansion, outline.disclosureScope.shouldRefresh(node.machine) {
            nodeActions.refreshMachine(node.machine)
        }
        // A machine's Ports summary is eager once its machine row is visible,
        // but a collapsed machine must stay lazy until this disclosure opens it.
        portsDemand.schedule(coordinator: self)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isUpdatingProgrammatically,
              let node = notification.userInfo?["NSObject"] as? CloudTreeNode,
              let outline = notification.object as? CloudTreeNSOutlineView,
              outline.disclosureScope.records(node, in: outline) else { return }
        expansionStore.setExpanded(false, node: node)
    }
}
