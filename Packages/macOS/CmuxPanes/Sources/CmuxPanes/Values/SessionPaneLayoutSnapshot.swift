public import Foundation

/// Persisted panel membership and selection for one Bonsplit leaf pane.
public struct SessionPaneLayoutSnapshot: Codable, Equatable, Sendable {
    /// Panel identities in tab-strip order.
    public var panelIds: [UUID]
    /// Selected panel identity, or nil for an empty pane.
    public var selectedPanelId: UUID?
    /// Whether the pane uses full-width tabs; nil for older snapshots.
    public var isFullWidthTabMode: Bool?

    /// Creates a leaf-pane snapshot.
    public init(
        panelIds: [UUID],
        selectedPanelId: UUID?,
        isFullWidthTabMode: Bool? = nil
    ) {
        self.panelIds = panelIds
        self.selectedPanelId = selectedPanelId
        self.isFullWidthTabMode = isFullWidthTabMode
    }
}
