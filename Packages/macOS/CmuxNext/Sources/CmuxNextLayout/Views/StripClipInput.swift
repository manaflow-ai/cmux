import CoreGraphics

/// What a host's strip clip is computed from (`clipToStrip`), in the host's own coordinates and cut to its
/// bounds: the clip depends only on these, so a pane that only moves (a strip pan, the camera) with the same
/// part of it clipped and covered has an equal input and keeps its clip.
struct StripClipInput: Equatable {
    var size: CGSize
    var clip: CGRect?
    var areaWindow: CGRect?
    var covers: [CGRect]

    /// The input of a host at `frame` (screen coordinates) with the strip `clip`, its scroll area's `areaWindow`
    /// and the frames of the panes in front of it (`covers`), all in screen coordinates.
    init(frame: CGRect, clip: CGRect?, areaWindow: CGRect?, covers: [CGRect]) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds) }
        size = frame.size
        self.clip = clip.map(local)
        self.areaWindow = areaWindow.map(local)
        self.covers = covers.map(local)
    }
}
