import CoreGraphics

/// What a host's strip clip is computed from (`clipToStrip`): the same input gives the same clip.
struct StripClipInput: Equatable {
    var frame: CGRect
    var clip: CGRect?
    var areaWindow: CGRect?
    var covers: [CGRect]
}
