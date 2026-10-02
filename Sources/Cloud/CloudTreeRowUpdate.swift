import AppKit

/// Resolves content changes to existing outline rows. Collapsed descendants
/// still adopt their new values; AppKit will configure them on expansion.
struct CloudTreeRowUpdate {
    let changedNodeIDs: Set<String>

    init(previous: [CloudTreeNodeContentSnapshot], next: [CloudTreeNodeContentSnapshot]) {
        // Structure and ordering are tracked separately. Compare by stable row
        // identity so an inserted or reordered descendant cannot make unrelated
        // rows appear changed through positional zip pairing.
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        changedNodeIDs = Set(next.compactMap { snapshot in
            previousByID[snapshot.id] == snapshot ? nil : snapshot.id
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
