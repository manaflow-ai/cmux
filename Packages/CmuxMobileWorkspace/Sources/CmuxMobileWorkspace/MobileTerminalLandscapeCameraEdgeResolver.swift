import Foundation

/// Pure resolver mapping a window orientation to the edge the camera sits on.
public struct MobileTerminalLandscapeCameraEdgeResolver {
    private init() {}

    /// Resolves the camera edge for the given orientation.
    /// - Parameter orientation: The current window orientation.
    /// - Returns: The edge the camera occupies; defaults to `.trailing` in portrait/unknown.
    public static func edge(for orientation: MobileTerminalWindowOrientation) -> MobileTerminalLandscapeCameraEdge {
        switch orientation {
        case .landscapeLeft:
            return .trailing
        case .landscapeRight:
            return .leading
        case .portrait, .portraitUpsideDown, .unknown:
            return .trailing
        }
    }
}
