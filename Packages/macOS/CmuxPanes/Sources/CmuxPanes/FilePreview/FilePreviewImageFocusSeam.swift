public import AppKit

/// Read-only focus seam the AppKit image preview surface uses to register its
/// focus endpoint and announce focus intent, without depending on the concrete
/// app-side `FilePreviewPanel`.
///
/// The app's `FilePreviewPanel` conforms to this and forwards into its
/// `FilePreviewFocusCoordinator`. The image container view holds `any
/// FilePreviewImageFocusSeam` so the view lives in `CmuxPanes` while focus
/// ownership stays app-side. It is `@MainActor` because AppKit focus state and
/// the panel's coordinator are both main-actor confined.
@MainActor
public protocol FilePreviewImageFocusSeam: AnyObject {
    /// Registers the image canvas focus endpoint so the panel's focus
    /// coordinator can route first-responder requests to it.
    func attachPreviewFocus(
        root: NSView,
        primaryResponder: NSView,
        intent: FilePreviewPanelFocusIntent
    )

    /// Records that the given focus intent is now the panel's preferred target,
    /// invoked when the image canvas becomes first responder.
    func noteFilePreviewFocusIntent(_ intent: FilePreviewPanelFocusIntent)
}
