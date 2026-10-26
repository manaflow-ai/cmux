import CoreGraphics

/// What a host's own clip is computed from (`clipToStrip`): its scroll area's window, in the host's
/// own coordinates and cut to its bounds. The strip's clip beside docked columns is not an input: the
/// strip container's bounds clip every strip pane (`StripClipContainerView`), so a host that moves or
/// resizes on a spring, or under a pan, with no area window has the same input on every frame and
/// computes nothing.
struct StripClipInput: Equatable {
    /// The host's size when an area window clips it; zero when nothing does.
    var size: CGSize
    var areaWindow: CGRect?

    /// The input of a host at `frame` (screen coordinates) in a scroll area whose window is `areaWindow`
    /// (screen coordinates), or in none.
    init(frame: CGRect, areaWindow: CGRect?) {
        guard let areaWindow else {
            (size, self.areaWindow) = (.zero, nil)
            return
        }
        let bounds = CGRect(origin: .zero, size: frame.size)
        size = frame.size
        self.areaWindow = areaWindow.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds)
    }
}
