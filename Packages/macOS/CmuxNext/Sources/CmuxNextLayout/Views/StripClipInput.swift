import CoreGraphics

/// What a host's own clip is computed from (`clipToStrip`), in the host's own coordinates and cut to
/// its bounds: its scroll area's window, and the strip's range it keeps while the strip container is
/// lifted for a zoom of another of its hosts (`ScreenContentView.heldStripClip`). The strip's clip
/// beside docked columns is otherwise not an input: the strip container's bounds clip every strip pane
/// (`StripClipContainerView`), so a host that moves or resizes on a spring, or under a pan, with
/// neither has the same input on every frame and computes nothing.
struct StripClipInput: Equatable {
    /// The host's size when something clips it; zero when nothing does.
    var size: CGSize
    var areaWindow: CGRect?
    var stripClip: CGRect?

    /// The input of a host at `frame` (screen coordinates) in a scroll area whose window is `areaWindow`,
    /// keeping `stripClip` of the strip's range (both in screen coordinates, nil for none).
    init(frame: CGRect, areaWindow: CGRect?, stripClip: CGRect? = nil) {
        guard areaWindow != nil || stripClip != nil else {
            (size, self.areaWindow, self.stripClip) = (.zero, nil, nil)
            return
        }
        let bounds = CGRect(origin: .zero, size: frame.size)
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds) }
        size = frame.size
        self.areaWindow = areaWindow.map(local)
        self.stripClip = stripClip.map(local)
    }

    /// True when the host has a clip of its own.
    var clipsHost: Bool { areaWindow != nil || stripClip != nil }
}
