public import CoreGraphics

/// Supplies hover-card thumbnails. The App implements it with a snapshot of
/// the terminal or web view; the demo draws fake content.
public protocol TabPreviewProvider: AnyObject {
    /// A thumbnail for `tab`, at most `maxPixelSize`. Nil shows a placeholder.
    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage?
}
