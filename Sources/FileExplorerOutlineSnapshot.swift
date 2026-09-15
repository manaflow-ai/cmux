import AppKit

/// The tree AppKit has been told about, independent of subsequent store mutations.
@MainActor
struct FileExplorerOutlineSnapshot {
    struct Structure: Equatable {
        let roots: [ObjectIdentifier]
        let children: [ObjectIdentifier: [ObjectIdentifier]]
    }

    struct Row: Equatable {
        let isLoading: Bool
        let error: String?
        let gitStatus: GitFileStatus?
    }

    let storeIdentity: ObjectIdentifier
    let roots: [FileExplorerNode]
    let children: [ObjectIdentifier: [FileExplorerNode]]
    let structure: Structure
    let rows: [ObjectIdentifier: Row]
    let expandedPaths: Set<String>
    let selectedPaths: Set<String>
    let selectedPath: String?

    init(store: FileExplorerStore) {
        storeIdentity = ObjectIdentifier(store)
        roots = store.rootNodes
        expandedPaths = store.expandedPaths
        selectedPaths = store.selectedPaths
        selectedPath = store.selectedPath
        var children: [ObjectIdentifier: [FileExplorerNode]] = [:]
        var childIDs: [ObjectIdentifier: [ObjectIdentifier]] = [:]
        var rows: [ObjectIdentifier: Row] = [:]
        var pending = roots
        while let node = pending.popLast() {
            let id = ObjectIdentifier(node)
            rows[id] = Row(isLoading: node.isLoading, error: node.error, gitStatus: store.gitStatusByPath[node.path])
            if let sorted = node.sortedChildren {
                children[id] = sorted
                childIDs[id] = sorted.map(ObjectIdentifier.init)
                pending.append(contentsOf: sorted)
            }
        }
        self.children = children
        self.rows = rows
        structure = Structure(roots: roots.map(ObjectIdentifier.init), children: childIDs)
    }

    func children(of item: Any?) -> [FileExplorerNode] {
        guard let item else { return roots }
        guard let node = item as? FileExplorerNode else { return [] }
        return children[ObjectIdentifier(node)] ?? []
    }

    func reconcileExpansion(in outlineView: NSOutlineView) {
        // Expanding inserts rows synchronously. Re-read the bound to restore
        // nested expansion in this pass, without waiting for another update.
        var row = 0
        while row < outlineView.numberOfRows {
            defer { row += 1 }
            guard let node = outlineView.item(atRow: row) as? FileExplorerNode,
                  node.isDirectory else { continue }
            let shouldExpand = expandedPaths.contains(node.path)
            if shouldExpand && !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
            } else if !shouldExpand && outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            }
        }
    }

    func refreshRealizedCells(previous: Self?, in outlineView: NSOutlineView) {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
            let id = ObjectIdentifier(node)
            guard previous?.rows[id] != rows[id],
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileExplorerCellView else { continue }
            cell.configure(with: node, gitStatus: rows[id]?.gitStatus)
        }
    }
}
