/// Reconciles a requested device orientation with the IOSurface's raw shape.
///
/// CoreSimulator versions differ: some keep a portrait IOSurface after a
/// rotation request, while others publish an already-rotated landscape
/// surface. This value is the single decision point for presentation and HID
/// input so cmux never double-rotates either side.
public struct SimulatorOrientationGeometry: Equatable, Sendable {
    /// Raw IOSurface width in pixels.
    public let rawWidth: Int
    /// Raw IOSurface height in pixels.
    public let rawHeight: Int
    /// The logical orientation requested from CoreSimulator.
    public let requestedOrientation: SimulatorOrientation
    /// Whether presentation and HID input require a raw-surface transform.
    public let needsRawTransform: Bool

    /// Creates geometry from raw IOSurface dimensions and requested orientation.
    public init(
        rawWidth: Int,
        rawHeight: Int,
        requestedOrientation: SimulatorOrientation
    ) {
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.requestedOrientation = requestedOrientation
        needsRawTransform = switch requestedOrientation {
        case .portrait:
            false
        case .portraitUpsideDown:
            true
        case .landscapeLeft, .landscapeRight:
            rawWidth <= rawHeight
        }
    }

    /// Creates geometry from worker display metadata.
    public init(display: SimulatorDisplayMetadata) {
        self.init(
            rawWidth: display.width,
            rawHeight: display.height,
            requestedOrientation: display.orientation
        )
    }

    /// Rotation applied to the raw Core Animation presentation, in degrees.
    public var presentationRotationDegrees: Int {
        guard needsRawTransform else { return 0 }
        return switch requestedOrientation {
        case .portrait: 0
        case .portraitUpsideDown: 180
        case .landscapeLeft: -90
        case .landscapeRight: 90
        }
    }

    /// Whether presentation width and height exchange axes.
    public var swapsAxes: Bool {
        abs(presentationRotationDegrees) == 90
    }

    /// Width of the display as presented to the user.
    public var displayWidth: Int {
        swapsAxes ? rawHeight : rawWidth
    }

    /// Height of the display as presented to the user.
    public var displayHeight: Int {
        swapsAxes ? rawWidth : rawHeight
    }

    /// Presented display aspect ratio, or zero for invalid raw dimensions.
    public var displayAspectRatio: Double {
        guard displayWidth > 0, displayHeight > 0 else { return 0 }
        return Double(displayWidth) / Double(displayHeight)
    }

    /// Maps a displayed normalized point back into raw IOSurface/HID space.
    public func rawPoint(for point: SimulatorPoint) -> SimulatorPoint {
        guard needsRawTransform else { return point }
        return switch requestedOrientation {
        case .portrait:
            point
        case .portraitUpsideDown:
            SimulatorPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeLeft:
            SimulatorPoint(x: point.y, y: 1 - point.x)
        case .landscapeRight:
            SimulatorPoint(x: 1 - point.y, y: point.x)
        }
    }

    /// Maps a displayed movement vector into raw IOSurface/HID space.
    public func rawDelta(for delta: SimulatorInputDelta) -> SimulatorInputDelta {
        guard needsRawTransform else { return delta }
        return switch requestedOrientation {
        case .portrait:
            delta
        case .portraitUpsideDown:
            SimulatorInputDelta(x: -delta.x, y: -delta.y)
        case .landscapeLeft:
            SimulatorInputDelta(x: delta.y, y: -delta.x)
        case .landscapeRight:
            SimulatorInputDelta(x: -delta.y, y: delta.x)
        }
    }

    /// Maps a displayed system-gesture edge into raw HID space.
    public func rawEdge(for edge: SimulatorEdge) -> SimulatorEdge {
        guard needsRawTransform else { return edge }
        return switch (requestedOrientation, edge) {
        case (_, .none): .none
        case (.portrait, _): edge
        case (.portraitUpsideDown, .left): .right
        case (.portraitUpsideDown, .right): .left
        case (.portraitUpsideDown, .top): .bottom
        case (.portraitUpsideDown, .bottom): .top
        case (.landscapeLeft, .left): .bottom
        case (.landscapeLeft, .right): .top
        case (.landscapeLeft, .top): .left
        case (.landscapeLeft, .bottom): .right
        case (.landscapeRight, .left): .top
        case (.landscapeRight, .right): .bottom
        case (.landscapeRight, .top): .right
        case (.landscapeRight, .bottom): .left
        }
    }

    /// Maps both touches and the gesture edge into raw HID space.
    public func rawPointerEvent(_ event: SimulatorPointerEvent) -> SimulatorPointerEvent {
        SimulatorPointerEvent(
            phase: event.phase,
            primary: rawPoint(for: event.primary),
            secondary: event.secondary.map(rawPoint(for:)),
            edge: rawEdge(for: event.edge)
        )
    }
}
