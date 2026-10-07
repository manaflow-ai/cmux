import AppKit
import CmuxCloudMachines

/// Resolves a machine drag against the frozen, displayed machine rows (the
/// roots, or the Cloud Machines section's children). Descendants are hover
/// targets for their machine's trailing edge, never new parents.
struct CloudMachineReorderDrop {
    let machineID: String
    let move: CloudMachineMove
    let childIndex: Int

    init?(
        sourceID: String, nodes: [CloudTreeNode], proposedItem: CloudTreeNode?,
        proposedChildIndex: Int, dropAfterItem: Bool
    ) {
        let proposedIndex: Int
        if let proposedItem {
            guard let rootIndex = nodes.firstIndex(where: {
                $0.canReorderMachine && $0.machine == proposedItem.machine
            }), nodes[rootIndex].id != sourceID else { return nil }
            let onHeader = nodes[rootIndex].id == proposedItem.id
                && proposedChildIndex == NSOutlineViewDropOnItemIndex
            proposedIndex = rootIndex + (onHeader && !dropAfterItem ? 0 : 1)
        } else {
            guard (0...nodes.count).contains(proposedChildIndex) else { return nil }
            proposedIndex = proposedChildIndex
        }
        self.init(sourceID: sourceID, nodes: nodes, proposedIndex: proposedIndex)
    }

    /// A drop at `slot` among the source's peers (its pin tier, without the
    /// source), as the lifted drag lays them out.
    init?(sourceID: String, nodes: [CloudTreeNode], slot: Int) {
        guard let source = nodes.first(where: { $0.id == sourceID }) else { return nil }
        let peers = nodes.indices.filter {
            nodes[$0].canReorderMachine && nodes[$0].isPinned == source.isPinned && nodes[$0].id != sourceID
        }
        guard (0...peers.count).contains(slot), let last = peers.last else { return nil }
        self.init(sourceID: sourceID, nodes: nodes, proposedIndex: slot < peers.count ? peers[slot] : last + 1)
    }

    private init?(sourceID: String, nodes: [CloudTreeNode], proposedIndex: Int) {
        guard let source = nodes.first(where: { $0.id == sourceID }),
              let machineID = source.machineOrderID else { return nil }
        let peerIndices = nodes.indices.filter {
            nodes[$0].canReorderMachine && nodes[$0].isPinned == source.isPinned
        }
        guard let first = peerIndices.first, let last = peerIndices.last else { return nil }
        // Match workspace reordering: crossing a pin boundary clamps the
        // destination into the original tier.
        let index = min(max(proposedIndex, first), last + 1)
        let peers = peerIndices.map { nodes[$0] }
        let remaining = peers.filter { $0.id != sourceID }
        let move: CloudMachineMove
        var preview = remaining.map(\.id)
        if let next = peerIndices.first(where: { $0 >= index && nodes[$0].id != sourceID }),
           let target = nodes[next].machineOrderID,
           let targetIndex = preview.firstIndex(of: nodes[next].id) {
            move = .before(target)
            preview.insert(sourceID, at: targetIndex)
        } else if let target = remaining.last?.machineOrderID {
            move = .after(target)
            preview.append(sourceID)
        } else { return nil }
        guard preview != peers.map(\.id) else { return nil }
        self.machineID = machineID
        self.move = move
        childIndex = index
    }
}
