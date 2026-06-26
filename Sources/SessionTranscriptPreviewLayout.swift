import CoreGraphics

/// Size bounds for the session-transcript preview popover: the size it opens at
/// plus the inclusive `[minSize, maxSize]` box the user may resize it within.
struct SessionTranscriptPreviewLayout: Equatable, Sendable {
    /// Size the preview popover opens at.
    let defaultSize: CGSize
    /// Smallest size the popover may be resized to.
    let minSize: CGSize
    /// Largest size the popover may be resized to.
    let maxSize: CGSize

    /// The standard session-transcript preview bounds.
    static let standard = SessionTranscriptPreviewLayout(
        defaultSize: CGSize(width: 520, height: 500),
        minSize: CGSize(width: 420, height: 320),
        maxSize: CGSize(width: 920, height: 820)
    )

    /// Clamp `size` into this layout's inclusive `[minSize, maxSize]` box.
    func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }
}
