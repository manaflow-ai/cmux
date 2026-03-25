import Foundation
import Combine

/// Manages parent-child workspace relationships in the sidebar.
/// Workspaces themselves hold their `childWorkspaceIds` and `isCollapsed` state.
/// This manager maintains the flat `items` array of top-level workspace IDs
/// and provides helper methods for tree operations.
///
/// Invariants:
/// - Every workspace appears at most once (either in `items` or as a child).
/// - No orphaned children — removing a parent cascades to children.
/// - Maximum nesting depth: 3 levels.
@MainActor
final class WorkspaceGroupManager: ObservableObject {

    @Published var items: [SidebarItem] = []
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: - Child Workspace Management

    /// Creates a new child workspace under the given parent.
    /// Returns nil if the parent is already at max depth (3).
    /// The caller is responsible for creating the actual Workspace object
    /// and adding it to TabManager.tabs.
    func addChildId(_ childId: UUID, to parentId: UUID) {
        guard let parent = tabManager?.workspace(for: parentId) else { return }
        parent.childWorkspaceIds.append(childId)
    }

    func removeChildId(_ childId: UUID, from parentId: UUID) {
        guard let parent = tabManager?.workspace(for: parentId) else { return }
        parent.childWorkspaceIds.removeAll { $0 == childId }
    }

    // MARK: - Top-Level Registration

    func registerWorkspaceAsStandalone(_ workspaceId: UUID) {
        guard !items.contains(workspaceId) else { return }
        // Don't register if it's already a child of another workspace
        guard parentWorkspace(of: workspaceId) == nil else { return }
        items.append(workspaceId)
    }

    /// Remove a workspace from the sidebar entirely (top-level and as child).
    func removeWorkspace(_ workspaceId: UUID) {
        items.removeAll { $0 == workspaceId }
        // Also remove from any parent's childWorkspaceIds
        if let parent = parentWorkspace(of: workspaceId) {
            parent.childWorkspaceIds.removeAll { $0 == workspaceId }
        }
    }

    // MARK: - Collapse

    func toggleCollapsed(_ workspaceId: UUID) {
        guard let ws = tabManager?.workspace(for: workspaceId), ws.hasChildren else { return }
        ws.isCollapsed.toggle()
    }

    // MARK: - Queries

    /// Find the parent workspace of a given workspace ID.
    func parentWorkspace(of childId: UUID) -> Workspace? {
        guard let tabManager else { return nil }
        return tabManager.tabs.first { ws in
            ws.childWorkspaceIds.contains(childId)
        }
    }

    /// Depth of a workspace: 1 for top-level, 2 for child, 3 for grandchild. 0 if not found.
    func depthOf(workspaceId: UUID) -> Int {
        if items.contains(workspaceId) { return 1 }
        guard let parent = parentWorkspace(of: workspaceId) else { return 0 }
        if items.contains(parent.id) { return 2 }
        if parentWorkspace(of: parent.id) != nil { return 3 }
        return 0
    }

    /// Flattened list of visible workspace IDs, skipping collapsed children.
    func visibleWorkspaces() -> [Workspace] {
        guard let tabManager else { return [] }
        var result: [Workspace] = []
        for wsId in items {
            guard let ws = tabManager.workspace(for: wsId) else { continue }
            result.append(ws)
            if ws.hasChildren && !ws.isCollapsed {
                collectVisibleChildren(of: ws, into: &result, tabManager: tabManager)
            }
        }
        return result
    }

    /// All workspace IDs that are descendants of the given workspace.
    func allDescendantIds(of workspaceId: UUID) -> [UUID] {
        guard let ws = tabManager?.workspace(for: workspaceId) else { return [] }
        var result: [UUID] = []
        collectDescendantIds(of: ws, into: &result)
        return result
    }

    // MARK: - Indent / Outdent (Tab / Shift-Tab)

    /// Indent: make the workspace a child of the sibling directly above it at the same level.
    /// Returns true if the mutation was applied.
    @discardableResult
    func indentWorkspace(_ workspaceId: UUID) -> Bool {
        guard let tabManager else { return false }

        // Case A: workspace is top-level
        if let idx = items.firstIndex(of: workspaceId) {
            guard idx > 0 else { return false }
            let siblingAboveId = items[idx - 1]
            guard let siblingAbove = tabManager.workspace(for: siblingAboveId) else { return false }
            // Check depth constraint: workspace + its descendants must not exceed depth 3
            let currentSubtreeDepth = maxDescendantDepth(of: workspaceId)
            let siblingDepth = depthOf(workspaceId: siblingAboveId)
            // After indent, workspace will be at siblingDepth + 1
            // Its deepest descendant will be at siblingDepth + 1 + (currentSubtreeDepth - 1)
            if siblingDepth + currentSubtreeDepth > 3 { return false }

            items.remove(at: idx)
            siblingAbove.childWorkspaceIds.append(workspaceId)
            return true
        }

        // Case B: workspace is a child of some parent
        if let parent = parentWorkspace(of: workspaceId) {
            guard let childIdx = parent.childWorkspaceIds.firstIndex(of: workspaceId),
                  childIdx > 0 else { return false }
            let siblingAboveId = parent.childWorkspaceIds[childIdx - 1]
            guard let siblingAbove = tabManager.workspace(for: siblingAboveId) else { return false }

            let currentSubtreeDepth = maxDescendantDepth(of: workspaceId)
            let siblingDepth = depthOf(workspaceId: siblingAboveId)
            if siblingDepth + currentSubtreeDepth > 3 { return false }

            parent.childWorkspaceIds.remove(at: childIdx)
            siblingAbove.childWorkspaceIds.append(workspaceId)
            return true
        }

        return false
    }

    /// Outdent: move the workspace to its parent's level, inserted right after its parent.
    /// Children come with it. Returns true if the mutation was applied.
    @discardableResult
    func outdentWorkspace(_ workspaceId: UUID) -> Bool {
        guard let tabManager else { return false }
        guard let parent = parentWorkspace(of: workspaceId) else { return false }

        // Remove from parent's children
        parent.childWorkspaceIds.removeAll { $0 == workspaceId }

        // Find where parent lives and insert after it
        if let grandparent = parentWorkspace(of: parent.id) {
            // Parent is a child itself — insert in grandparent's children after parent
            if let parentIdx = grandparent.childWorkspaceIds.firstIndex(of: parent.id) {
                grandparent.childWorkspaceIds.insert(workspaceId, at: parentIdx + 1)
            }
        } else if let parentTopIdx = items.firstIndex(of: parent.id) {
            // Parent is top-level — insert in items after parent
            items.insert(workspaceId, at: parentTopIdx + 1)
        }

        return true
    }

    /// Maximum depth of the subtree rooted at the given workspace (1 = leaf).
    private func maxDescendantDepth(of workspaceId: UUID) -> Int {
        guard let ws = tabManager?.workspace(for: workspaceId) else { return 1 }
        if ws.childWorkspaceIds.isEmpty { return 1 }
        var maxChild = 0
        for childId in ws.childWorkspaceIds {
            maxChild = max(maxChild, maxDescendantDepth(of: childId))
        }
        return 1 + maxChild
    }

    // MARK: - Private

    private func collectVisibleChildren(
        of workspace: Workspace, into result: inout [Workspace], tabManager: TabManager
    ) {
        for childId in workspace.childWorkspaceIds {
            guard let child = tabManager.workspace(for: childId) else { continue }
            result.append(child)
            if child.hasChildren && !child.isCollapsed {
                collectVisibleChildren(of: child, into: &result, tabManager: tabManager)
            }
        }
    }

    private func collectDescendantIds(of workspace: Workspace, into result: inout [UUID]) {
        for childId in workspace.childWorkspaceIds {
            result.append(childId)
            if let child = tabManager?.workspace(for: childId) {
                collectDescendantIds(of: child, into: &result)
            }
        }
    }
}
