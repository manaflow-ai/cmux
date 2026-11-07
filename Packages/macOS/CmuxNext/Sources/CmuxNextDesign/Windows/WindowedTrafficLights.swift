public import AppKit

/// A window's traffic lights in their last windowed place: their left edge, their top's distance from the window's top,
/// and their size. A window that leaves full screen puts them back there at once, and it may come back at another
/// height, so the place is kept from the window's top.
public struct WindowedTrafficLights: Sendable {
    private var place: (x: CGFloat, fromTop: CGFloat, size: CGSize)?

    public init() {}

    /// The lights a layout found at `lights` (window coordinates) in a window `windowHeight` tall; kept only while the
    /// window is `windowed` (not in or leaving full screen).
    public mutating func note(_ lights: CGRect, windowHeight: CGFloat, windowed: Bool) {
        guard windowed else { return }
        place = (lights.minX, windowHeight - lights.maxY, lights.size)
    }

    /// Where the lights go in a window `windowHeight` tall; nil before any was noted.
    public func resting(windowHeight: CGFloat) -> CGRect? {
        guard let place else { return nil }
        return CGRect(x: place.x, y: windowHeight - place.fromTop - place.size.height, width: place.size.width, height: place.size.height)
    }
}
