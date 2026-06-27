public import Bonsplit

/// One `NSSplitView` ancestor's geometry, as the `layout_debug` command reports
/// it for a selected panel.
///
/// The app-side witness walks the panel's view ancestry (forcing a layout pass
/// per split view) and fills these primitive leaves plus Bonsplit ``PixelRect``
/// frames; this value type owns only the wire shape. The declared property
/// order is the wire order: synthesized `Codable` encodes in declaration order,
/// so the emitted JSON is byte-identical to the legacy app-side struct.
public struct LayoutDebugSplitView: Codable, Sendable {
    /// Whether the split view is vertical.
    public let isVertical: Bool
    /// The split view's divider thickness, in points.
    public let dividerThickness: Double
    /// The split view's bounds rectangle.
    public let bounds: PixelRect
    /// The split view's frame in its window, when available.
    public let frame: PixelRect?
    /// The window-space frames of the split view's arranged subviews.
    public let arrangedSubviewFrames: [PixelRect]
    /// The divider position normalized to `[0, 1]`, when computable.
    public let normalizedDividerPosition: Double?

    /// Creates a split-view debug record from already-read geometry leaves.
    ///
    /// - Parameters:
    ///   - isVertical: Whether the split view is vertical.
    ///   - dividerThickness: The divider thickness, in points.
    ///   - bounds: The split view's bounds rectangle.
    ///   - frame: The split view's frame in its window, when available.
    ///   - arrangedSubviewFrames: The window-space frames of the arranged subviews.
    ///   - normalizedDividerPosition: The divider position normalized to `[0, 1]`.
    public init(
        isVertical: Bool,
        dividerThickness: Double,
        bounds: PixelRect,
        frame: PixelRect?,
        arrangedSubviewFrames: [PixelRect],
        normalizedDividerPosition: Double?
    ) {
        self.isVertical = isVertical
        self.dividerThickness = dividerThickness
        self.bounds = bounds
        self.frame = frame
        self.arrangedSubviewFrames = arrangedSubviewFrames
        self.normalizedDividerPosition = normalizedDividerPosition
    }
}
