public import CoreGraphics

/// A single pane reported by tmux in character-cell coordinates, used by the
/// experimental tmux-active-pane overlay to position a highlight over the pane
/// tmux considers active.
public struct TmuxPaneLayoutPane: Codable, Equatable, Sendable {
    /// tmux's identifier for the pane.
    public let paneId: String
    /// Left edge of the pane, in character cells from the surface origin.
    public let left: Int
    /// Top edge of the pane, in character cells from the surface origin.
    public let top: Int
    /// Pane width in character cells.
    public let width: Int
    /// Pane height in character cells.
    public let height: Int
    /// Whether tmux currently considers this pane the active one.
    public let isActive: Bool

    /// Creates a tmux pane layout entry.
    /// - Parameters:
    ///   - paneId: tmux's pane identifier.
    ///   - left: left edge in character cells.
    ///   - top: top edge in character cells.
    ///   - width: width in character cells.
    ///   - height: height in character cells.
    ///   - isActive: whether tmux marks this pane active.
    public init(paneId: String, left: Int, top: Int, width: Int, height: Int, isActive: Bool) {
        self.paneId = paneId
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.isActive = isActive
    }

    /// The overlay rect for this pane within a terminal surface.
    /// - Parameters:
    ///   - surfaceFrame: the surface frame the pane lives in.
    ///   - cellSize: the size of one character cell in points.
    /// - Returns: the pane's pixel rect, or `nil` when the cell size or pane
    ///   dimensions are degenerate.
    public func overlayRect(surfaceFrame: CGRect, cellSize: CGSize) -> CGRect? {
        guard cellSize.width > 0,
              cellSize.height > 0,
              width > 0,
              height > 0 else {
            return nil
        }

        return CGRect(
            x: surfaceFrame.origin.x + (CGFloat(left) * cellSize.width),
            y: surfaceFrame.origin.y + (CGFloat(top) * cellSize.height),
            width: CGFloat(width) * cellSize.width,
            height: CGFloat(height) * cellSize.height
        )
    }
}
