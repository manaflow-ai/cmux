public import Foundation

/// One pending native browser dialog (was the controller-private
/// `V2BrowserPendingDialog`), redesigned as a `Sendable` value: instead of
/// carrying the WKWebView completion handler as a closure, it carries a
/// `dialogID` key. The app side keeps the completion handler keyed by that id
/// and runs it when the accept/dismiss decision comes back through
/// `ControlBrowserAutomationContext.controlBrowserResolvePendingDialog(dialogID:accept:text:)`.
public struct ControlBrowserPendingDialog: Sendable, Equatable {
    /// The key the app side stores the WKWebView completion handler under.
    public let dialogID: UUID
    /// The browser surface that raised the dialog.
    public let surfaceID: UUID
    /// The dialog kind (the legacy `type` wire field: `alert`, `confirm`,
    /// `prompt`, …).
    public let kind: String
    /// The dialog message text.
    public let message: String
    /// The prompt's default text, if the dialog is a prompt.
    public let defaultText: String?

    /// Creates a pending-dialog value.
    ///
    /// - Parameters:
    ///   - dialogID: The completion-handler key.
    ///   - surfaceID: The browser surface that raised the dialog.
    ///   - kind: The dialog kind (legacy `type` field).
    ///   - message: The dialog message text.
    ///   - defaultText: The prompt's default text, if any.
    public init(dialogID: UUID, surfaceID: UUID, kind: String, message: String, defaultText: String?) {
        self.dialogID = dialogID
        self.surfaceID = surfaceID
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
    }
}
