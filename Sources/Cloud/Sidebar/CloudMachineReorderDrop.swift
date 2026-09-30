import AppKit
import CmuxCloudMachines

/// Resolves a machine drag against the frozen, displayed roots. Descendants
/// are hover targets for their machine's trailing edge, never new parents.
struct CloudMachineReorderDrop {
    let machineID: String
    let move: CloudMachineMove
    let childIndex: Int

    init?(
        sourceID: String, nodes: [CloudTreeNode], proposedItem: CloudTreeNode?,
        proposedChildIndex: Int, dropAfterItem: Bool
    ) {
        guard let source = nodes.first(where: { $0.id == sourceID }),
              let machineID = source.machineOrderID else { return nil }
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

        let peerIndices = nodes.indices.filter {
            nodes[$0].canReorderMachine && nodes[$0].isPinned == source.isPinned
        }
        guard let first = peerIndices.first, let last = peerIndices.last else { return nil }
        // Match workspace reordering: crossing a pin boundary clamps the
        // destination into the original tier, including the painted line.
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
