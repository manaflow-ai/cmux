public import Foundation
public import CoreGraphics

/// Decides whether an unhandled native drag may move its live source into a new window.
public struct DragOutWindowPolicy {
    /// Creates the policy without application state.
    public init() {}

    /// Requires a confirmed release outside every visible window in this process.
    /// - Parameters:
    ///   - accepted: Whether AppKit reported a destination accepting the drag.
    ///   - mouseReleased: Whether a mouse-up from this native session was observed.
    ///   - cancelled: Whether Escape was observed during this session.
    ///   - point: The native completion point in AppKit screen coordinates.
    ///   - windowFrames: Visible same-process windows, including auxiliary windows.
    /// - Returns: Whether the caller may transfer its validated live capability.
    public func shouldDetach(
        accepted: Bool, mouseReleased: Bool, cancelled: Bool,
        point: CGPoint, windowFrames: [CGRect]
    ) -> Bool {
        !accepted && mouseReleased && !cancelled
            && point.x.isFinite && point.y.isFinite
            && !windowFrames.contains(where: { $0.contains(point) })
    }

    /// Places a new window near the release point inside the selected display's usable frame.
    /// - Parameters:
    ///   - size: The destination window's current size.
    ///   - point: The release point in AppKit screen coordinates.
    ///   - visibleFrame: The chosen display's frame excluding the menu bar and Dock.
    /// - Returns: A frame with an accessible title bar, including on displays with negative origins.
    public func frame(size: CGSize, near point: CGPoint, visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let preferredX: CGFloat = point.x - width / CGFloat(2)
        let preferredY: CGFloat = point.y - height + CGFloat(20)
        let x: CGFloat = min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - width)
        let y: CGFloat = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
