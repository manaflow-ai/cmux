import Foundation

/// Pure resolver mapping a window orientation to the edge the camera sits on.
public struct MobileTerminalLandscapeCameraEdgeResolver {
    private init() {}

    /// Resolves the camera edge for the given orientation.
    /// - Parameters:
    ///   - orientation: The current window orientation.
    ///   - isRightToLeft: Whether the layout direction is right-to-left, so the
    ///     camera's physical side maps to the opposite leading/trailing edge.
    /// - Returns: The edge the camera occupies; defaults to the physical right
    ///   side in portrait/unknown so a protected edge is always available.
    public static func edge(
        for orientation: MobileTerminalWindowOrientation,
        isRightToLeft: Bool = false
    ) -> MobileTerminalLandscapeCameraEdge {
        // Physical side first: interface orientation `.landscapeLeft` puts the
        // device top (camera) on the right edge, `.landscapeRight` on the left.
        // Leading/trailing then follow the layout direction.
        let cameraIsOnRight: Bool
        switch orientation {
        case .landscapeLeft:
            cameraIsOnRight = true
        case .landscapeRight:
            cameraIsOnRight = false
        case .portrait, .portraitUpsideDown, .unknown:
            cameraIsOnRight = true
        }
        if isRightToLeft {
            return cameraIsOnRight ? .leading : .trailing
        }
        return cameraIsOnRight ? .trailing : .leading
    }
}
