public import CoreGraphics

/// Supplies hover-card thumbnails. The App implements it with a snapshot of
/// the terminal or web view; the demo draws fake content.
public protocol TabPreviewProvider: AnyObject {
    /// A thumbnail for `tab`, at most `maxPixelSize`. Nil shows a placeholder.
    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage?

    /// Shows `tab` live to `onImage` while a card shows it: its last picture now, then each new one after its content
    /// changed. Returns the stop the card calls when it hides; nil when the provider pictures on request only
    /// (``previewImage(for:maxPixelSize:)``).
    func watchPreview(for tab: TabID, maxPixelSize: CGSize, onImage: @escaping @MainActor (CGImage) -> Void) -> (@MainActor () -> Void)?

    /// The theme changed: pictures kept for ``watchPreview(for:maxPixelSize:onImage:)`` are taken again.
    func invalidatePreviews()
}

extension TabPreviewProvider {
    public func watchPreview(for tab: TabID, maxPixelSize: CGSize, onImage: @escaping @MainActor (CGImage) -> Void) -> (@MainActor () -> Void)? { nil }
    public func invalidatePreviews() {}
}
