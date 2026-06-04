/// The result of one geometry pass, delivered as a
/// ``GhosttySurfaceHostEvent/geometryMeasured(_:)`` event.
public struct GhosttySurfaceGeometryMeasurement: Sendable, Equatable {
    /// The request that produced this measurement (carries the trigger
    /// context the main-actor consumer needs to apply it).
    public let request: GhosttySurfaceGeometryRequest
    /// The natural grid measured at the container size.
    public let natural: GhosttySurfaceMeasuredSize
    /// Cell width in pixels derived from the natural measurement (0 when the
    /// measurement was degenerate).
    public let cellPixelWidth: Double
    /// Cell height in pixels derived from the natural measurement.
    public let cellPixelHeight: Double
    /// Letterboxed render size in points when the surface was fitted to the
    /// request's pin; `nil` means fill the container's natural size.
    public let pinnedSize: GhosttySurfacePinnedSize?

    /// Creates a measurement.
    /// - Parameters:
    ///   - request: The originating request.
    ///   - natural: The measured natural grid.
    ///   - cellPixelWidth: Derived cell width in pixels.
    ///   - cellPixelHeight: Derived cell height in pixels.
    ///   - pinnedSize: Letterboxed render size in points, if pinned.
    public init(
        request: GhosttySurfaceGeometryRequest,
        natural: GhosttySurfaceMeasuredSize,
        cellPixelWidth: Double,
        cellPixelHeight: Double,
        pinnedSize: GhosttySurfacePinnedSize?
    ) {
        self.request = request
        self.natural = natural
        self.cellPixelWidth = cellPixelWidth
        self.cellPixelHeight = cellPixelHeight
        self.pinnedSize = pinnedSize
    }
}

/// A letterboxed render size in points.
public struct GhosttySurfacePinnedSize: Sendable, Equatable {
    /// Render width in points.
    public let width: Double
    /// Render height in points.
    public let height: Double

    /// Creates a pinned size.
    /// - Parameters:
    ///   - width: Render width in points.
    ///   - height: Render height in points.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
