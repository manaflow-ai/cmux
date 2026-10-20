/// The size and backing scale of the host's sidebar surface, in points.
///
/// Sent host → worker on layout and backing-scale changes (kept separate from
/// ``RenderScene`` so live sidebar resizes don't re-send the full data
/// context). The worker sizes its offscreen render surface to match, so the
/// shared layer maps 1:1 onto the host view with no transform.
public struct RenderSurfaceGeometry: Codable, Sendable, Equatable {
    /// Surface width in points.
    public var width: Double
    /// Surface height in points.
    public var height: Double
    /// Backing scale factor of the host screen (2.0 on Retina), so the worker
    /// rasterizes layer contents crisply.
    public var scale: Double

    /// Creates a surface geometry.
    ///
    /// - Parameters:
    ///   - width: Surface width in points.
    ///   - height: Surface height in points.
    ///   - scale: Backing scale factor of the host screen.
    public init(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}
