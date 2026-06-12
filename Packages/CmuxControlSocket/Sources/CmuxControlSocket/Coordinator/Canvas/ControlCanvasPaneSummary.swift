public import Foundation

/// One canvas pane in a `canvas.info` snapshot, ordered back-to-front.
public struct ControlCanvasPaneSummary: Sendable, Equatable {
    /// The wire surface id (the workspace panel UUID).
    public let surfaceID: UUID
    public let frame: ControlCanvasFrame
    public let isFocused: Bool

    public init(surfaceID: UUID, frame: ControlCanvasFrame, isFocused: Bool) {
        self.surfaceID = surfaceID
        self.frame = frame
        self.isFocused = isFocused
    }
}
