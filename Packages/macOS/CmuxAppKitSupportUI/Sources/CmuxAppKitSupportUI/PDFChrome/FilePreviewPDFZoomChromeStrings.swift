/// The localized, user-facing strings rendered by the file-preview PDF zoom
/// chrome bar (``FilePreviewPDFZoomChromeView``).
///
/// Resolved app-side (where `String(localized:)` binds to the app bundle, which
/// owns the `filePreview.pdf.*` catalog keys) and injected into the package
/// view. Resolving them app-side is deliberate: a package calling
/// `String(localized:)` binds to the *package* bundle, which holds none of these
/// catalog entries, so every non-English localization would silently fall back
/// to the English `defaultValue`. Passing the already-resolved values keeps the
/// chrome bar byte-identical in every locale after the move.
public struct FilePreviewPDFZoomChromeStrings: Sendable, Equatable {
    /// Label for the system control-group variant (`filePreview.pdf.zoomControls`).
    public let zoomControls: String
    /// Accessibility/help label for the zoom-out button (`filePreview.pdf.zoomOut`).
    public let zoomOut: String
    /// Accessibility/help label for the actual-size button (`filePreview.pdf.actualSize`).
    public let actualSize: String
    /// Accessibility/help label for the zoom-in button (`filePreview.pdf.zoomIn`).
    public let zoomIn: String
    /// Accessibility/help label for the zoom-to-fit button (`filePreview.pdf.zoomToFit`).
    public let zoomToFit: String
    /// Accessibility/help label for the rotate-left button (`filePreview.pdf.rotateLeft`).
    public let rotateLeft: String
    /// Accessibility/help label for the rotate-right button (`filePreview.pdf.rotateRight`).
    public let rotateRight: String

    /// Creates the PDF zoom chrome string bundle.
    public init(
        zoomControls: String,
        zoomOut: String,
        actualSize: String,
        zoomIn: String,
        zoomToFit: String,
        rotateLeft: String,
        rotateRight: String
    ) {
        self.zoomControls = zoomControls
        self.zoomOut = zoomOut
        self.actualSize = actualSize
        self.zoomIn = zoomIn
        self.zoomToFit = zoomToFit
        self.rotateLeft = rotateLeft
        self.rotateRight = rotateRight
    }
}
