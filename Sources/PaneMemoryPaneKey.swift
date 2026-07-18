import Foundation

/// Stable identity of a single pane (workspace + panel) for guardrail tracking.
struct PaneMemoryPaneKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}
