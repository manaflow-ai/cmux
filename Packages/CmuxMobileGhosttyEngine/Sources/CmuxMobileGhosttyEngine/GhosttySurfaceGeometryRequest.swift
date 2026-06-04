/// Inputs for one coalesced geometry pass on the session's serial executor.
///
/// Mirrors the pre-existing `syncSurfaceGeometry` contract: push the
/// container size (and content scale when it changed), read back the natural
/// grid, and — when a ``GhosttySurfaceGridPin`` is set and smaller than the
/// natural grid — fit the surface to the pinned grid to produce a letterboxed
/// render size.
public struct GhosttySurfaceGeometryRequest: Sendable, Equatable {
    /// Container width in points (≥ 1).
    public let containerWidth: Double
    /// Container height in points (≥ 1), already minus reserved bottom UI.
    public let containerHeight: Double
    /// Display scale (points → pixels).
    public let scale: Double
    /// Content scale to push before sizing, or `nil` when unchanged.
    public let contentScaleToApply: Double?
    /// Effective shared grid to pin to, or `nil` to fill the container.
    public let pin: GhosttySurfaceGridPin?
    /// Echoed back on the resulting measurement so the main-actor consumer
    /// can correlate a measurement with the trigger that requested it.
    public let reassertNaturalSize: Bool

    /// Creates a geometry request.
    /// - Parameters:
    ///   - containerWidth: Container width in points.
    ///   - containerHeight: Container height in points.
    ///   - scale: Display scale (points → pixels).
    ///   - contentScaleToApply: Content scale to push first, or `nil`.
    ///   - pin: Effective shared grid to pin to, or `nil`.
    ///   - reassertNaturalSize: Echoed through to the measurement.
    public init(
        containerWidth: Double,
        containerHeight: Double,
        scale: Double,
        contentScaleToApply: Double?,
        pin: GhosttySurfaceGridPin?,
        reassertNaturalSize: Bool
    ) {
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
        self.scale = scale
        self.contentScaleToApply = contentScaleToApply
        self.pin = pin
        self.reassertNaturalSize = reassertNaturalSize
    }
}
