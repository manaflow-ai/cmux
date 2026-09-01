public import Foundation

/// Selects the deterministic ordering used for a cross-workspace task queue.
public enum ControlWorkspaceTaskQueueSortKey: String, Sendable, Equatable {
    /// Most recently active rows first.
    case activity
    /// In-progress, pending, and completed rows in lifecycle order.
    case status
    /// Workspace title first, then task state and text.
    case workspace
}
