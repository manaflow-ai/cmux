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
        dropAfterItem: Bool,
        liftSlot: Int? = nil
    ) {
        if let scope = CloudMachineReorderScope(machineNodeID: sourceID, roots: nodes) {
            let drop: CloudMachineReorderDrop?
            if let liftSlot {
                // A lifted drag drops where it shows the machine, not where
                // AppKit's row proposal happens to point.
                drop = CloudMachineReorderDrop(sourceID: sourceID, nodes: scope.siblings, slot: liftSlot)
            } else {
                // Between two machines in the section, AppKit proposes the
                // section itself with a child index.
                let item = proposedItem === scope.parent ? nil : proposedItem
                drop = CloudMachineReorderDrop(
                    sourceID: sourceID, nodes: scope.siblings, proposedItem: item,
                    proposedChildIndex: proposedChildIndex, dropAfterItem: dropAfterItem
                )
            }
            guard let drop else { return nil }
            self.sourceID = sourceID
            parent = scope.parent
            children = scope.siblings
            childIndex = drop.childIndex
            operation = .machine(drop.machineID, drop.move)
            return
        }
        guard let parent = CloudSidebarOrganizationTree(nodes: nodes).parent(of: sourceID) else { return nil }
        let group = parent.organizationGroupID
        let pinned = state.isPinned(sourceID, parent: group)
        let index: Int
        if let liftSlot {
            // A lifted workspace lands where the rows show it: at `liftSlot`
            // among the other rows of its pin tier.
            let peers = parent.children.indices.filter { index in
                let child = parent.children[index]
                return child.canOrganize && child.id != sourceID && state.isPinned(child.id, parent: group) == pinned
            }
            guard (0...peers.count).contains(liftSlot), let last = peers.last else { return nil }
            index = liftSlot < peers.count ? peers[liftSlot] : last + 1
        } else if let proposedItem, proposedItem.id == parent.id, proposedChildIndex >= 0 {
            guard proposedChildIndex <= parent.children.count else { return nil }
            index = proposedChildIndex
        } else {
            guard let proposedItem else { return nil }
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
        let before = parent.children.prefix(index).last { $0.canOrganize && $0.id != sourceID }
        let after = parent.children.dropFirst(index).first { $0.canOrganize && $0.id != sourceID }
        let action: CloudSidebarOrganizationAction
        if let after, state.isPinned(after.id, parent: group) == pinned {
            action = .before(after.id)
        } else if let before, state.isPinned(before.id, parent: group) == pinned {
            action = .after(before.id)
        } else { return nil }
        let siblings = parent.children.filter(\.canOrganize).map(\.id)
        var preview = state
        guard preview.apply(action, id: sourceID, siblings: siblings, parent: group),
              preview.ordered(siblings, parent: group) != state.ordered(siblings, parent: group) else { return nil }
        self.sourceID = sourceID
        self.parent = parent
        children = parent.children
        self.childIndex = index
        operation = .organization(action)
    }
}
