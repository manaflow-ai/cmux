public import Foundation

/// A window's move-target inputs, supplied by the app shim to
/// ``PaneSurfaceMoveCoordinator`` so it can build the ``WorkspaceMoveTarget``
/// list without reaching live `TabManager`/`Workspace` state.
///
/// The legacy `AppDelegate.workspaceMoveTargets(excludingWorkspaceId:
/// referenceWindowId:)` iterated the ordered main-window summaries, resolved a
/// per-window display label, and projected every workspace in each window's
/// `TabManager`. The window ordering and the localized window labels are
/// window-domain, app-bundle concerns that stay app-side; the host resolves
/// them and hands the coordinator this already-ordered, already-labelled value
/// list. The coordinator then owns the exclusion filter and the per-workspace
/// ``WorkspaceMoveTarget`` projection (the loop the god kept inline).
///
/// `Sendable, Equatable` value type naming no app type.
public struct PaneSurfaceMoveWindowSummary: Sendable, Equatable {
    /// One destination workspace in this window.
    public struct Workspace: Sendable, Equatable {
        /// The workspace's identifier.
        public let workspaceId: UUID
        /// The workspace's resolved display title (app-side
        /// `workspaceDisplayName`, with the localized fallback already applied).
        public let title: String

        /// Creates a destination workspace from its id and display title.
        public init(workspaceId: UUID, title: String) {
            self.workspaceId = workspaceId
            self.title = title
        }
    }

    /// The window's identifier.
    public let windowId: UUID
    /// The window's resolved display label (e.g. "Current Window", "Window 2").
    public let windowLabel: String
    /// Whether this is the reference (current) window.
    public let isCurrentWindow: Bool
    /// The window's workspaces, in tab order.
    public let workspaces: [Workspace]

    /// Creates a window summary from its identity, label, current-window flag,
    /// and ordered workspace list.
    public init(
        windowId: UUID,
        windowLabel: String,
        isCurrentWindow: Bool,
        workspaces: [Workspace]
    ) {
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.isCurrentWindow = isCurrentWindow
        self.workspaces = workspaces
    }
}
