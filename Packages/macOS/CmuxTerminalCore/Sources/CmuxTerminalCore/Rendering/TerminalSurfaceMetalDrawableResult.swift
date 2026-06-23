public import CoreGraphics

/// The outcome of asking the host to apply a Metal drawable size during a
/// surface-size update.
///
/// ``TerminalSurfaceRenderCoordinator`` uses this to reproduce the legacy
/// `updateSurfaceSize()` branch: when the backing layer is a realized
/// `CAMetalLayer` it clears the non-Metal retry state and possibly marks a size
/// change; otherwise it schedules a deferred retry until the Metal layer
/// realizes. Keeping the AppKit layer access in the host while the retry
/// bookkeeping stays in the coordinator preserves byte-for-byte behavior.
public struct TerminalSurfaceMetalDrawableResult: Sendable {
    /// Whether the host backing layer is a realized `CAMetalLayer`.
    public let metalLayerRealized: Bool

    /// Whether the drawable size was actually changed on the Metal layer.
    public let drawableSizeChanged: Bool

    /// The drawable size the coordinator should cache as `lastDrawableSize`.
    ///
    /// When the Metal layer is realized this is the requested size once applied;
    /// otherwise it is the coordinator's prior cached value, unchanged.
    public let newLastDrawableSize: CGSize

    /// Creates a Metal drawable application result.
    ///
    /// - Parameters:
    ///   - metalLayerRealized: Whether the layer is a realized `CAMetalLayer`.
    ///   - drawableSizeChanged: Whether the drawable size changed.
    ///   - newLastDrawableSize: The size to cache as `lastDrawableSize`.
    public init(
        metalLayerRealized: Bool,
        drawableSizeChanged: Bool,
        newLastDrawableSize: CGSize
    ) {
        self.metalLayerRealized = metalLayerRealized
        self.drawableSizeChanged = drawableSizeChanged
        self.newLastDrawableSize = newLastDrawableSize
    }
}
