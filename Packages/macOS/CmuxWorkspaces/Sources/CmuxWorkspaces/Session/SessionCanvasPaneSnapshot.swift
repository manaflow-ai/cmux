public import Foundation

/// One canvas pane's persisted geometry, ordered back-to-front so restore
/// reproduces the z-order.
public struct SessionCanvasPaneSnapshot: Codable, Equatable, Sendable {
    /// The pane identity (its founding panel's UUID). Pre-tab snapshots
    /// stored the single hosted panel here.
    public var panelId: UUID
    /// Pane frame origin x in canvas coordinates.
    public var x: Double
    /// Pane frame origin y in canvas coordinates.
    public var y: Double
    /// Pane frame width.
    public var width: Double
    /// Pane frame height.
    public var height: Double
    /// Ordered tabs. Absent in pre-tab snapshots (treated as `[panelId]`).
    public var panelIds: [UUID]? = nil
    /// Selected tab. Absent in pre-tab snapshots (treated as `panelId`).
    public var selectedPanelId: UUID? = nil

    /// Creates a persisted canvas pane snapshot.
    public init(
        panelId: UUID,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        panelIds: [UUID]? = nil,
        selectedPanelId: UUID? = nil
    ) {
        self.panelId = panelId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.panelIds = panelIds
        self.selectedPanelId = selectedPanelId
    }
}
