public import CoreGraphics

/// The sizing bounds for the transcript preview popover.
///
/// A real value type carrying the default/min/max sizes plus the clamp, rather than a
/// caseless static namespace. ``standard`` is the production configuration; tests can
/// construct other bounds. `clamped(_:)` constrains a proposed size to `[minSize, maxSize]`.
public struct SessionTranscriptPreviewLayout: Sendable, Equatable {
    /// The size used when a preview first opens.
    public let defaultSize: CGSize
    /// The smallest size the user may resize the preview to.
    public let minSize: CGSize
    /// The largest size the user may resize the preview to.
    public let maxSize: CGSize

    /// Creates a layout with explicit default/min/max sizes.
    public init(defaultSize: CGSize, minSize: CGSize, maxSize: CGSize) {
        self.defaultSize = defaultSize
        self.minSize = minSize
        self.maxSize = maxSize
    }

    /// The production transcript-preview sizing.
    public static let standard = SessionTranscriptPreviewLayout(
        defaultSize: CGSize(width: 520, height: 500),
        minSize: CGSize(width: 420, height: 320),
        maxSize: CGSize(width: 920, height: 820)
    )

    /// Constrains a proposed size to `[minSize, maxSize]` on each axis.
    public func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }
}
