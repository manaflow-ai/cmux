public import Foundation

/// An opaque handle for a focused panel within a workspace, surfaced by
/// ``FocusedNotificationResolving/focusedPanel(forTabId:surfaceId:)``. The
/// marker routes every panel predicate/mutation by `tabId`/`panelId` and never
/// holds the concrete `Workspace`. Mirrors the app-target
/// `FocusedPanelNotificationTarget` (workspace + panelId), reduced to ids.
public struct FocusedPanel: Sendable, Hashable {
    /// The id of the workspace (tab) that owns the panel.
    public let tabId: UUID
    /// The id of the focused panel within the workspace.
    public let panelId: UUID

    /// Creates a focused-panel handle.
    public init(tabId: UUID, panelId: UUID) {
        self.tabId = tabId
        self.panelId = panelId
    }
}
