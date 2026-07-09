public import CmuxFoundation

/// Narrow read/write seam the file-explorer outline navigator uses to drive the
/// selection and expansion source of truth without depending on the app-target
/// `FileExplorerStore`.
///
/// The navigator only needs the navigation-anchor paths plus the expand/collapse
/// and select mutators; the broader store (root nodes, git status, prefetch,
/// providers) stays app-side. The app's `FileExplorerStore` conforms to this
/// protocol so the navigator can read ``selectedPath``/``selectedPaths`` after a
/// reload and mutate the logical selection/expansion state in the same order the
/// AppKit coordinator did before the extraction.
public protocol FileExplorerNavigationStore: AnyObject {
    /// The keyboard/navigation anchor path the outline view mirrors after reloads.
    var selectedPath: String? { get }
    /// The stable multi-selection set; ``selectedPath`` remains the anchor within it.
    var selectedPaths: Set<String> { get }

    /// Whether the node is logically expanded (persisted across provider changes).
    func isExpanded(_ node: FileExplorerNode) -> Bool
    /// Marks the directory node logically expanded.
    func expand(node: FileExplorerNode)
    /// Marks the directory node logically collapsed.
    func collapse(node: FileExplorerNode)
    /// Sets the single navigation selection to the node (or clears it when nil).
    func select(node: FileExplorerNode?)
    /// Records that the directory's first child should be selected once its async
    /// load completes.
    func requestDescendIntoFirstChild(of node: FileExplorerNode)
}
