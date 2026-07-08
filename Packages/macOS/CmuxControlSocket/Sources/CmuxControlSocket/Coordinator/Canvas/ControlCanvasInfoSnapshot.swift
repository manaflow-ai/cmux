public import Foundation

/// The `canvas.info` snapshot: the resolved workspace's layout mode and, when
/// in canvas mode, its pane geometry in z-order (back to front).
public struct ControlCanvasInfoSnapshot: Sendable, Equatable {
    public let workspaceID: UUID
    /// `"canvas"` or `"splits"`.
    public let mode: String
    public let panes: [ControlCanvasPaneSummary]
    /// Current viewport magnification; `nil` outside canvas mode or when no
    /// viewport is attached.
    public let magnification: Double?
    /// Current viewport center X, in canvas coordinates; `nil` when
    /// `magnification` is.
    public let centerX: Double?
    /// Current viewport center Y, in canvas coordinates; `nil` when
    /// `magnification` is.
    public let centerY: Double?

    public init(
        workspaceID: UUID,
        mode: String,
        panes: [ControlCanvasPaneSummary],
        magnification: Double? = nil,
        centerX: Double? = nil,
        centerY: Double? = nil
    ) {
        self.workspaceID = workspaceID
        self.mode = mode
        self.panes = panes
        self.magnification = magnification
        self.centerX = centerX
        self.centerY = centerY
    }
}
