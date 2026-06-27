public import AppKit
public import CmuxSidebar
import CmuxFoundation

/// Path-owned keyboard navigation for the file-explorer `NSOutlineView`.
///
/// The navigator is the single writer of programmatic outline selection: it
/// resolves the store's logical selection paths to outline rows, moves/expands/
/// collapses the selection in response to right-sidebar keys, and type-to-select
/// quick-search matches. It owns ``isUpdatingOutlineProgrammatically`` so the
/// owning AppKit coordinator can suppress its `outlineViewSelectionDidChange`
/// delegate reaction while the navigator drives the selection, and exposes
/// ``withProgrammaticOutlineUpdate(_:)`` so the coordinator's reload/expansion
/// paths reuse the same guard. The selection/expansion source of truth lives
/// behind the ``FileExplorerNavigationStore`` seam (the app's `FileExplorerStore`).
@MainActor
public final class FileExplorerOutlineNavigator {
    /// The selection/expansion source of truth. Reassigned by the owner whenever
    /// the SwiftUI representable hands the coordinator a new store instance.
    public var store: any FileExplorerNavigationStore

    /// True while the navigator (or the owner via
    /// ``withProgrammaticOutlineUpdate(_:)``) is mutating the outline selection,
    /// so the owner's selection-change delegate ignores the echo.
    public private(set) var isUpdatingOutlineProgrammatically = false

    public init(store: any FileExplorerNavigationStore) {
        self.store = store
    }

    // MARK: - Path-Owned Navigation

    public func ensureSelection(in outlineView: NSOutlineView, fallbackToFirstVisible: Bool, scroll: Bool) {
        withProgrammaticOutlineUpdate {
            applyStoredSelection(in: outlineView, fallbackToFirstVisible: fallbackToFirstVisible, scroll: scroll)
        }
    }

    public func moveSelection(in outlineView: NSOutlineView, by delta: Int) {
        guard outlineView.numberOfRows > 0 else {
            store.select(node: nil)
            return
        }
        let currentRow = resolvedSelectionRow(in: outlineView) ?? (delta >= 0 ? -1 : outlineView.numberOfRows)
        let targetRow = min(max(currentRow + delta, 0), outlineView.numberOfRows - 1)
        selectRow(targetRow, in: outlineView, scroll: true)
    }

    public func performDisclosureAction(
        _ action: RightSidebarDisclosureAction,
        in outlineView: NSOutlineView
    ) {
        switch action {
        case .collapse:
            collapseSelectedItemOrMoveToParent(in: outlineView)
        case .expand:
            expandSelectedItemOrMoveToChild(in: outlineView)
        }
    }

    public func selectBestQuickSearchMatch(in outlineView: NSOutlineView, query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, outlineView.numberOfRows > 0 else { return }
        let lowerQuery = trimmedQuery.lowercased()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
            if node.name.lowercased().contains(lowerQuery) {
                selectRow(row, in: outlineView, scroll: true)
                return
            }
        }
    }

    private func expandSelectedItemOrMoveToChild(in outlineView: NSOutlineView) {
        guard let row = resolvedSelectionRow(in: outlineView),
              let node = outlineView.item(atRow: row) as? FileExplorerNode,
              node.isDirectory else {
            return
        }

        selectRow(row, in: outlineView, scroll: true)

        if !store.isExpanded(node) {
            outlineView.expandItem(node)
            applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: true)
            return
        }

        guard node.children != nil else {
            store.requestDescendIntoFirstChild(of: node)
            return
        }

        if !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        }
        selectFirstChild(of: node, in: outlineView)
    }

    private func collapseSelectedItemOrMoveToParent(in outlineView: NSOutlineView) {
        guard let row = resolvedSelectionRow(in: outlineView),
              let node = outlineView.item(atRow: row) as? FileExplorerNode else {
            return
        }

        if node.isDirectory, outlineView.isItemExpanded(node) || store.isExpanded(node) {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                store.collapse(node: node)
            }
            selectRow(row, in: outlineView, scroll: true)
            return
        }

        selectParent(of: node, in: outlineView)
    }

    private func selectFirstChild(of node: FileExplorerNode, in outlineView: NSOutlineView) {
        let parentRow = outlineView.row(forItem: node)
        let childRow = parentRow + 1
        guard parentRow >= 0,
              childRow < outlineView.numberOfRows,
              let child = outlineView.item(atRow: childRow) as? FileExplorerNode,
              (outlineView.parent(forItem: child) as? FileExplorerNode) === node else {
            return
        }
        selectRow(childRow, in: outlineView, scroll: true)
    }

    private func selectParent(of node: FileExplorerNode, in outlineView: NSOutlineView) {
        guard let parentNode = outlineView.parent(forItem: node) as? FileExplorerNode else {
            return
        }
        let parentRow = outlineView.row(forItem: parentNode)
        guard parentRow >= 0 else { return }
        selectRow(parentRow, in: outlineView, scroll: true)
    }

    public func applyStoredSelection(
        in outlineView: NSOutlineView,
        fallbackToFirstVisible: Bool,
        scroll: Bool
    ) {
        let exactRows = store.selectedPaths.reduce(into: IndexSet()) { if let resolution = selectionResolution(for: $1, in: outlineView), resolution.isExact { $0.insert(resolution.row) } }
        if !exactRows.isEmpty {
            withProgrammaticOutlineUpdate { outlineView.selectRowIndexes(exactRows, byExtendingSelection: false) }
            let anchorRow = store.selectedPath.flatMap { selectionResolution(for: $0, in: outlineView)?.row }
            if scroll, let row = exactRows.scrollAnchorRow(preferring: anchorRow) { outlineView.scrollRowToVisible(row) }; return
        }
        if let selectedPath = store.selectedPath,
           let resolution = selectionResolution(for: selectedPath, in: outlineView) {
            selectRow(
                resolution.row,
                in: outlineView,
                scroll: scroll,
                updateStore: resolution.isExact
            )
            return
        }
        guard fallbackToFirstVisible, outlineView.numberOfRows > 0 else { return }
        selectRow(0, in: outlineView, scroll: scroll)
    }

    private func resolvedSelectionRow(in outlineView: NSOutlineView) -> Int? {
        if let selectedPath = store.selectedPath,
           let resolution = selectionResolution(for: selectedPath, in: outlineView) {
            return resolution.row
        }
        guard outlineView.selectedRow >= 0,
              outlineView.selectedRow < outlineView.numberOfRows,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode else {
            return nil
        }
        store.select(node: node)
        return outlineView.selectedRow
    }

    private func selectionResolution(for path: String, in outlineView: NSOutlineView) -> FileExplorerSelectionResolution? {
        var candidates: [(row: Int, path: String)] = []
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
            candidates.append((row, node.path))
        }
        return FileExplorerSelectionResolution.resolve(target: path, in: candidates)
    }

    private func selectRow(
        _ row: Int,
        in outlineView: NSOutlineView,
        scroll: Bool,
        updateStore: Bool = true
    ) {
        guard row >= 0, row < outlineView.numberOfRows else { return }
        let node = outlineView.item(atRow: row) as? FileExplorerNode
        withProgrammaticOutlineUpdate {
            if updateStore {
                store.select(node: node)
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scroll {
                outlineView.scrollRowToVisible(row)
            }
        }
    }

    public func withProgrammaticOutlineUpdate(_ body: () -> Void) {
        let wasUpdating = isUpdatingOutlineProgrammatically
        isUpdatingOutlineProgrammatically = true
        defer { isUpdatingOutlineProgrammatically = wasUpdating }
        body()
    }
}
