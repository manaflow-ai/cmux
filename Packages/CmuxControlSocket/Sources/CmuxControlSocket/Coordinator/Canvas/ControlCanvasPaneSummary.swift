public import Foundation

/// One canvas pane in a `canvas.info` snapshot, ordered back-to-front.
public struct ControlCanvasPaneSummary: Sendable, Equatable {
    /// The pane identity (its founding panel's UUID).
    public let surfaceID: UUID
    public let frame: ControlCanvasFrame
    /// Whether the pane hosts the workspace's focused panel.
    public let isFocused: Bool
    /// Hosted tabs (wire surface ids), left to right.
    public let panelIDs: [UUID]
    /// The selected tab's wire surface id.
    public let selectedPanelID: UUID

    public init(
        surfaceID: UUID,
        frame: ControlCanvasFrame,
        isFocused: Bool,
        panelIDs: [UUID],
        selectedPanelID: UUID
    ) {
        self.surfaceID = surfaceID
        self.frame = frame
        self.isFocused = isFocused
        self.panelIDs = panelIDs
        self.selectedPanelID = selectedPanelID
    }
}
