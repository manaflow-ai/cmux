import Foundation

/// Semantic row content, without reflection or derived drag-payload allocation.
/// The implicit drag group is a pure function of `kind`; only an explicit
/// workspace group carries information not already represented there.
struct CloudTreeNodeContentSnapshot: Equatable {
    let id: String
    let kind: CloudTreeNode.Kind
    let explicitDragGroup: SurfaceResourceGroup?
}
