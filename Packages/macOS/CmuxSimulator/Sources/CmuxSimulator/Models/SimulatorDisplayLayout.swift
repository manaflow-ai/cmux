/// Computes aspect-fit display geometry and normalized input coordinates.
public struct SimulatorDisplayLayout: Equatable, Sendable {
    /// The host pane geometry.
    public let surface: SimulatorSurfaceGeometry
    /// The current device display metadata.
    public let display: SimulatorDisplayMetadata

    /// Creates a display layout.
    public init(surface: SimulatorSurfaceGeometry, display: SimulatorDisplayMetadata) {
        self.surface = surface
        self.display = display
    }

    /// The device framebuffer's aspect-fit rectangle inside the host pane.
    public var contentRect: SimulatorRect {
        guard surface.width > 0, surface.height > 0, display.width > 0, display.height > 0 else {
            return SimulatorRect(x: 0, y: 0, width: 0, height: 0)
        }
        let deviceAspect = SimulatorOrientationGeometry(display: display).displayAspectRatio
        guard deviceAspect > 0 else {
            return SimulatorRect(x: 0, y: 0, width: 0, height: 0)
        }
        let hostAspect = surface.width / surface.height
        if hostAspect > deviceAspect {
            let height = surface.height
            let width = height * deviceAspect
            return SimulatorRect(x: (surface.width - width) / 2, y: 0, width: width, height: height)
        }
        let width = surface.width
        let height = width / deviceAspect
        return SimulatorRect(x: 0, y: (surface.height - height) / 2, width: width, height: height)
    }

    /// Maps a host-view point into normalized top-left-origin device coordinates.
    /// - Parameters:
    ///   - x: The host point's x coordinate.
    ///   - y: The host point's bottom-left-origin y coordinate.
    /// - Returns: A normalized point, or `nil` when the point lies outside the display.
    public func normalizedPoint(x: Double, y: Double) -> SimulatorPoint? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0,
              x >= rect.x, x <= rect.x + rect.width,
              y >= rect.y, y <= rect.y + rect.height else {
            return nil
        }
        return SimulatorPoint(
            x: (x - rect.x) / rect.width,
            y: 1 - ((y - rect.y) / rect.height)
        )
    }
}
