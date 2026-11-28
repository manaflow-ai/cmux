import Foundation
import CmuxCanvas

/// Where inside a canvas pane a mouse-down landed.
enum CanvasPaneHitRegion: Equatable {
    /// The title strip: starts a move drag.
    case titleBar
    /// A border band or corner: starts a resize drag for the given edges.
    case resize(CanvasResizeEdges)
}
