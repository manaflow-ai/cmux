/// The localized accessibility/help labels rendered by the file-preview image
/// chrome bar (``FilePreviewImageChromeView``).
///
/// Resolved app-side (where `String(localized:)` binds to the app bundle, which
/// owns the `filePreview.image.*` catalog keys) and injected into the package
/// view, for the same bundle-localization reason documented on
/// ``FilePreviewPDFSidebarChromeStrings``.
public struct FilePreviewImageChromeStrings: Sendable, Equatable {
    /// Label for the zoom-out button (`filePreview.image.zoomOut`).
    public let zoomOut: String
    /// Label for the actual-size button (`filePreview.image.actualSize`).
    public let actualSize: String
    /// Label for the zoom-in button (`filePreview.image.zoomIn`).
    public let zoomIn: String
    /// Label for the zoom-to-fit button (`filePreview.image.zoomToFit`).
    public let zoomToFit: String
    /// Label for the rotate-left button (`filePreview.image.rotateLeft`).
    public let rotateLeft: String
    /// Label for the rotate-right button (`filePreview.image.rotateRight`).
    public let rotateRight: String

    /// Creates the image chrome string bundle.
    public init(
        zoomOut: String,
        actualSize: String,
        zoomIn: String,
        zoomToFit: String,
        rotateLeft: String,
        rotateRight: String
    ) {
        self.zoomOut = zoomOut
        self.actualSize = actualSize
        self.zoomIn = zoomIn
        self.zoomToFit = zoomToFit
        self.rotateLeft = rotateLeft
        self.rotateRight = rotateRight
    }
}
