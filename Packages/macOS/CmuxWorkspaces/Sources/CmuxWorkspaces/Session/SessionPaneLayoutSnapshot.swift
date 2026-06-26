public import Foundation

/// A persisted leaf pane in a workspace layout snapshot: the ordered panel
/// ids it hosts and which one was selected.
public struct SessionPaneLayoutSnapshot: Codable, Sendable {
    /// Ordered panel identities hosted by this pane.
    public var panelIds: [UUID]
    /// The selected panel, or `nil` when the pane has no selection.
    public var selectedPanelId: UUID?

    /// Creates a persisted pane snapshot.
    public init(panelIds: [UUID], selectedPanelId: UUID?) {
        self.panelIds = panelIds
        self.selectedPanelId = selectedPanelId
    }
}
