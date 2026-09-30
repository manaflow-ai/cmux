import CmuxFileTree
import Foundation

/// Receives incremental Files tree changes from ``FileExplorerStore``.
///
/// The store mutates its node graph first, then calls the observer, so an
/// `NSOutlineView` data source reading the store during the callback sees the
/// final state. The outline coordinator is the only production observer.
@MainActor
protocol FileExplorerTreeObserving: AnyObject {
    /// The whole tree was replaced (new root, provider or reset).
    func fileExplorerTreeDidReset(_ store: FileExplorerStore)

    /// `parent`'s children changed; `nil` means the root level.
    /// - Parameters:
    ///   - diff: Removals in old coordinates and insertions in new ones.
    ///   - updatedNodes: Surviving children whose metadata changed in place.
    func fileExplorerTree(
        _ store: FileExplorerStore,
        didUpdateChildrenOf parent: FileExplorerNode?,
        diff: FileTreeChildrenDiff,
        updatedNodes: [FileExplorerNode]
    )

    /// Rows whose loading state, error or git status changed.
    func fileExplorerTree(_ store: FileExplorerStore, didRefreshRowsFor nodes: [FileExplorerNode])

    /// Rows the store wants expanded: restored state or a recursive expansion.
    func fileExplorerTree(_ store: FileExplorerStore, expand nodes: [FileExplorerNode])

    /// The store changed the selection itself.
    func fileExplorerTreeDidChangeSelection(_ store: FileExplorerStore, scrollToAnchor: Bool)

    /// Start inline renaming of a row that just appeared.
    func fileExplorerTree(_ store: FileExplorerStore, beginRenaming node: FileExplorerNode)

    /// Scroll so `node` is `offset` points above the viewport top.
    func fileExplorerTree(_ store: FileExplorerStore, restoreScrollTo node: FileExplorerNode, offset: Double)

    /// The row at the viewport top and how far it is scrolled past, for saving.
    func fileExplorerTreeScrollAnchor(_ store: FileExplorerStore) -> (path: String, offset: Double)?
}
