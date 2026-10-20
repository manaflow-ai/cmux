/// The logical orientation of a simulated display.
public enum SimulatorOrientation: String, Codable, CaseIterable, Sendable {
    /// Upright portrait orientation.
    case portrait
    /// Portrait rotated 180 degrees.
    case portraitUpsideDown = "portrait_upside_down"
    /// Landscape with the device's left edge at the top.
    case landscapeLeft = "landscape_left"
    /// Landscape with the device's right edge at the top.
    case landscapeRight = "landscape_right"

    /// The next counter-clockwise orientation used by the pane toolbar.
    public var rotatedLeft: SimulatorOrientation {
        switch self {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .portraitUpsideDown
        case .portraitUpsideDown: .landscapeRight
        case .landscapeRight: .portrait
        }
    }
}
