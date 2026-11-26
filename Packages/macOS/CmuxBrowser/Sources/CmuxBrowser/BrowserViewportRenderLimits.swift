/// Bounds the WebKit geometry produced by combining an emulated viewport with page zoom.
public struct BrowserViewportRenderLimits: Equatable, Sendable {
    /// The production limits used by cmux browser surfaces.
    public static let standard = BrowserViewportRenderLimits(
        standardMaximumDimension: 8_192,
        maximumArea: 33_554_432
    )

    /// Largest supported width or height in WebKit view coordinates.
    public let maximumDimension: Double

    /// Largest supported area in WebKit view coordinates.
    public let maximumArea: Double

    /// Creates positive finite render limits.
    ///
    /// - Parameters:
    ///   - maximumDimension: Largest supported width or height.
    ///   - maximumArea: Largest supported width multiplied by height.
    public init?(maximumDimension: Double, maximumArea: Double) {
        guard maximumDimension.isFinite,
              maximumArea.isFinite,
              maximumDimension > 0,
              maximumArea > 0 else {
            return nil
        }
        self.maximumDimension = maximumDimension
        self.maximumArea = maximumArea
    }

    private init(standardMaximumDimension: Double, maximumArea: Double) {
        maximumDimension = standardMaximumDimension
        self.maximumArea = maximumArea
    }

    /// Returns the largest page zoom that keeps a viewport inside both limits.
    ///
    /// - Parameter viewport: Logical CSS viewport to project into WebKit coordinates.
    /// - Returns: Maximum positive page zoom allowed for the viewport.
    public func maximumPageZoom(for viewport: BrowserViewport) -> Double {
        let width = Double(viewport.width)
        let height = Double(viewport.height)
        let dimensionZoom = min(maximumDimension / width, maximumDimension / height)
        let areaZoom = (maximumArea / (width * height)).squareRoot()
        return min(dimensionZoom, areaZoom)
    }

    /// Reports whether a viewport and page zoom fit inside both render limits.
    ///
    /// - Parameters:
    ///   - viewport: Logical CSS viewport to project into WebKit coordinates.
    ///   - pageZoom: WebKit page zoom to apply.
    /// - Returns: `true` when the combined geometry is supported.
    public func supports(viewport: BrowserViewport, pageZoom: Double) -> Bool {
        guard pageZoom.isFinite, pageZoom > 0 else { return false }
        return pageZoom <= maximumPageZoom(for: viewport)
    }
}
