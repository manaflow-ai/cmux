import Foundation

/// Semantic row content, without reflection or derived drag-payload allocation.
/// The implicit drag group is a pure function of `kind`; only an explicit
/// workspace group carries information not already represented there.
struct CloudTreeNodeContentSnapshot: Equatable {
    let id: String
    let kind: CloudTreeNode.Kind
    let explicitDragGroup: SurfaceResourceGroup?
    let isPinned: Bool
    let hasUnreadAttention: Bool
    let resourceSection: CloudTreeMachineResourceSection?

    init(
        id: String,
        kind: CloudTreeNode.Kind,
        explicitDragGroup: SurfaceResourceGroup?,
        isPinned: Bool = false,
        hasUnreadAttention: Bool = false,
        resourceSection: CloudTreeMachineResourceSection? = nil
    ) {
        self.id = id
        self.kind = kind
        self.explicitDragGroup = explicitDragGroup
        self.isPinned = isPinned
        self.hasUnreadAttention = hasUnreadAttention
        self.resourceSection = resourceSection
    }
}
