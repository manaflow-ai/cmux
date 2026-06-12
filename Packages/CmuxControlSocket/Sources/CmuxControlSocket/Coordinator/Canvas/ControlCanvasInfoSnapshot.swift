public import Foundation

/// The `canvas.info` snapshot: the resolved workspace's layout mode and, when
/// in canvas mode, its pane geometry in z-order (back to front).
public struct ControlCanvasInfoSnapshot: Sendable, Equatable {
    public let workspaceID: UUID
    /// `"canvas"` or `"splits"`.
    public let mode: String
    public let panes: [ControlCanvasPaneSummary]

    public init(workspaceID: UUID, mode: String, panes: [ControlCanvasPaneSummary]) {
        self.workspaceID = workspaceID
        self.mode = mode
        self.panes = panes
    }
}
