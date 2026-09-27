import CmuxCloud
import AppKit

/// Converts AppKit's hierarchy-relative proposal into a move among displayed
/// siblings. Stable IDs route to the existing descendant or machine order owner.
struct CloudSidebarOrganizationDrop {
    let sourceID: String
    let parent: CloudTreeNode?
    let children: [CloudTreeNode]
    let childIndex: Int
    let operation: CloudSidebarDropOperation

    init?(
        sourceID: String,
        nodes: [CloudTreeNode],
        state: CloudSidebarOrganizationState,
        proposedItem: CloudTreeNode?,
        proposedChildIndex: Int,
        dropAfterItem: Bool
    ) {
        if nodes.contains(where: { $0.id == sourceID && $0.canReorderMachine }) {
            guard let drop = CloudMachineReorderDrop(
                sourceID: sourceID, nodes: nodes, proposedItem: proposedItem,
                proposedChildIndex: proposedChildIndex, dropAfterItem: dropAfterItem
            ) else { return nil }
            self.sourceID = sourceID
            parent = nil
            children = nodes
            childIndex = drop.childIndex
            operation = .machine(drop.machineID, drop.move)
            return
        }
        guard let parent = CloudSidebarOrganizationTree(nodes: nodes).parent(of: sourceID),
              let proposedItem else { return nil }
        let index: Int
        if proposedItem.id == parent.id, proposedChildIndex >= 0 {
            guard proposedChildIndex <= parent.children.count else { return nil }
            index = proposedChildIndex
        } else {
            // A folder cannot contain its sibling. AppKit nevertheless proposes
            // drop-on and child insertions while hovering an expanded folder.
            // Retarget to that folder's outer edge without opening or reparenting.
            guard let siblingIndex = parent.children.firstIndex(where: { sibling in
                sibling.canOrganize && CloudTreeNodeBuilder.flattened([sibling]).contains { $0.id == proposedItem.id }
            }) else { return nil }
            let sibling = parent.children[siblingIndex]
            guard sibling.id != sourceID else { return nil }
            let onSibling = sibling.id == proposedItem.id && proposedChildIndex == NSOutlineViewDropOnItemIndex
            index = siblingIndex + (onSibling && !dropAfterItem ? 0 : 1)
        }
        let pinned = state.isPinned(sourceID, parent: parent.id)
        let before = parent.children.prefix(index).last { $0.canOrganize && $0.id != sourceID }
        let after = parent.children.dropFirst(index).first { $0.canOrganize && $0.id != sourceID }
        let action: CloudSidebarOrganizationAction
        if let after, state.isPinned(after.id, parent: parent.id) == pinned {
            action = .before(after.id)
        } else if let before, state.isPinned(before.id, parent: parent.id) == pinned {
            action = .after(before.id)
        } else { return nil }
        let siblings = parent.children.filter(\.canOrganize).map(\.id)
        var preview = state
        guard preview.apply(action, id: sourceID, siblings: siblings, parent: parent.id),
              preview.ordered(siblings, parent: parent.id) != state.ordered(siblings, parent: parent.id) else { return nil }
        self.sourceID = sourceID
        self.parent = parent
        children = parent.children
        self.childIndex = index
        operation = .organization(action)
    }
}
