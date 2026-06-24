public import AppKit

/// Read-only seam the AppKit PDF preview surface uses to register its focus
/// endpoints, announce focus intent, query the panel's current intent, and ask
/// the app to re-sync keyboard focus, without depending on the concrete
/// app-side `FilePreviewPanel`.
///
/// The app's `FilePreviewPanel` conforms to this and forwards into its
/// `FilePreviewFocusCoordinator` and `AppDelegate`. The PDF container view holds
/// `any FilePreviewPDFFocusSeam` so the view lives in `CmuxPanes` while focus
/// ownership and the app keyboard-focus reconciliation stay app-side. It refines
/// ``FilePreviewImageFocusSeam`` so it inherits endpoint registration and
/// intent announcement, adding the PDF-only intent query and keyboard-sync hook.
/// It is `@MainActor` because AppKit focus state, the panel's coordinator, and
/// the app delegate are all main-actor confined.
@MainActor
public protocol FilePreviewPDFFocusSeam: FilePreviewImageFocusSeam {
    /// The PDF-region focus intent the panel currently owns in the given window,
    /// or `nil` when no PDF region holds focus there.
    func currentFilePreviewFocusIntent(in window: NSWindow?) -> FilePreviewPanelFocusIntent?

    /// Asks the app to reconcile its keyboard focus after the PDF surface changed
    /// the window's first responder.
    func syncKeyboardFocus(in window: NSWindow?)
}
