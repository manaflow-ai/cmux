import Foundation

/// The outcome of snapping a dragged or resized frame.
public struct CanvasSnapResult: Hashable, Sendable {
    /// The frame after snapping. Equal to the proposed frame when nothing snapped.
    public let frame: CanvasRect
    /// Guides to render while the snap is active. Empty when nothing snapped.
    public let guides: [CanvasGuide]

    /// Creates a snap result.
    ///
    /// - Parameters:
    ///   - frame: The frame after snapping.
    ///   - guides: Guides to render while the snap is active.
    public init(frame: CanvasRect, guides: [CanvasGuide]) {
        self.frame = frame
        self.guides = guides
    }
}
