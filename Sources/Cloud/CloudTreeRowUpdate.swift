import AppKit

/// Resolves content changes to existing outline rows. Collapsed descendants
/// still adopt their new values; AppKit will configure them on expansion.
struct CloudTreeRowUpdate {
    let changedNodeIDs: Set<String>

    init(previous: [CloudTreeNodeContentSnapshot], next: [CloudTreeNodeContentSnapshot]) {
        changedNodeIDs = Set(zip(previous, next).compactMap { old, new in
            old == new ? nil : new.id
        })
    }

    @MainActor
    func rowIndexes(in outline: NSOutlineView) -> IndexSet {
        IndexSet((0..<outline.numberOfRows).filter { row in
            guard let node = outline.item(atRow: row) as? CloudTreeNode else { return false }
            return changedNodeIDs.contains(node.id)
        })
    }
}
