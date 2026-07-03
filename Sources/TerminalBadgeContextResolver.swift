import CmuxSettings
import CmuxTerminal
import Foundation

/// Resolves the per-surface ``TerminalBadgeContext`` (workspace/tab names and
/// indices) for a terminal surface, so the badge overlay never reaches into the
/// workspace/tab model directly.
///
/// The resolver is a thin, value-typed read over the app's workspace model. It
/// is created on demand by the surface's pane host and produces an immutable
/// snapshot; it holds no state and triggers no mutation, so it is safe to call
/// from `@MainActor` view code on every badge refresh.
@MainActor
struct TerminalBadgeContextResolver {
    /// The surface whose badge context is being resolved.
    let surface: TerminalSurface

    /// Creates a resolver for one surface.
    ///
    /// - Parameter surface: The surface to resolve identity for.
    init(surface: TerminalSurface) {
        self.surface = surface
    }

    /// Computes the current badge substitution context for ``surface``.
    ///
    /// Fields that cannot be resolved (e.g. the surface is not yet attached to a
    /// workspace) are left `nil`, which renders as the empty string.
    ///
    /// - Returns: The resolved ``TerminalBadgeContext``.
    func resolve() -> TerminalBadgeContext {
        guard let workspace = surface.owningWorkspace() else {
            return TerminalBadgeContext()
        }
        return TerminalBadgeContext(
            workspace: workspace.title,
            tab: resolvedTabTitle(in: workspace),
            tabIndex: resolvedTabIndex(in: workspace),
            workspaceIndex: resolvedWorkspaceIndex(of: workspace)
        )
    }

    /// The surface's split-tab title from the workspace's split controller, or
    /// `nil`.
    ///
    /// The bonsplit "tab" is keyed by the surface's *panel* id (`surface.id`),
    /// not the surface's `tabId` (which identifies the owning workspace), so the
    /// panel id is first mapped to a `TabID` via `surfaceIdFromPanelId(_:)`.
    private func resolvedTabTitle(in workspace: Workspace) -> String? {
        guard let tabId = workspace.surfaceIdFromPanelId(surface.id),
              let title = workspace.bonsplitController.tab(tabId)?.title,
              !title.isEmpty
        else {
            return nil
        }
        return title
    }

    /// The surface's 1-based position among its sibling split-tabs in the same
    /// pane, or `nil` when the surface is not found in any pane.
    private func resolvedTabIndex(in workspace: Workspace) -> Int? {
        guard let zeroBased = workspace.indexInPane(forPanelId: surface.id) else { return nil }
        return zeroBased + 1
    }

    /// The workspace's 1-based position in its tab manager's workspace list (the
    /// number the user sees in the sidebar), or `nil` when unavailable.
    private func resolvedWorkspaceIndex(of workspace: Workspace) -> Int? {
        guard let tabManager = workspace.owningTabManager else { return nil }
        guard let zeroBased = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
            return nil
        }
        return zeroBased + 1
    }
}
