/// The localized canvas-domain error messages, resolved against the app bundle.
///
/// The coordinator owns socket parameter validation and error-envelope shaping,
/// but it must not call `String(localized:)` inside this package. The package
/// bundle has no localization resources, so app-side conformers pass the
/// already-resolved strings through this value.
public struct ControlCanvasStrings: Sendable, Equatable {
    /// `control.canvas.error.invalidMode`.
    public let invalidMode: String
    /// `control.canvas.error.notCanvasOrZoomable`.
    public let notCanvasOrZoomable: String
    /// `control.canvas.error.requiresFreeformCanvas`.
    public let requiresFreeformCanvas: String

    /// Creates the localized canvas strings.
    ///
    /// - Parameters:
    ///   - invalidMode: The invalid layout-mode parameter message.
    ///   - notCanvasOrZoomable: The active-viewport-required message.
    ///   - requiresFreeformCanvas: The freeform-canvas-required message.
    public init(
        invalidMode: String,
        notCanvasOrZoomable: String,
        requiresFreeformCanvas: String
    ) {
        self.invalidMode = invalidMode
        self.notCanvasOrZoomable = notCanvasOrZoomable
        self.requiresFreeformCanvas = requiresFreeformCanvas
    }
}
