public import AppKit

/// A window's traffic lights at their last windowed place, kept while it is in full screen: their left edge, their
/// top's distance from the window's top, and their size (the window may come back from full screen at another
/// height). While the window leaves full screen the lights come back to that place.
public struct WindowedTrafficLights {
    private var place: (x: CGFloat, fromTop: CGFloat, size: CGSize)?

    public init() {}

    /// The root's layout reports the lights it found (window coordinates) in `window`; ignored in full screen and
    /// while the window leaves it.
    public mutating func note(_ lights: CGRect, in window: NSWindow, leavingFullScreen: Bool) {
        guard !window.styleMask.contains(.fullScreen), !leavingFullScreen else { return }
        place = (lights.minX, window.frame.height - lights.maxY, lights.size)
    }

    /// Where the lights come back to in `window` while it leaves full screen; nil otherwise or before a note.
    public func resting(in window: NSWindow, leavingFullScreen: Bool) -> CGRect? {
        guard leavingFullScreen, let place else { return nil }
        return CGRect(x: place.x, y: window.frame.height - place.fromTop - place.size.height, width: place.size.width, height: place.size.height)
    }
}
