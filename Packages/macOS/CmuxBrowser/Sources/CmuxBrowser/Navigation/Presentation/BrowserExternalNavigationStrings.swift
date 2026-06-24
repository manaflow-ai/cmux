public import Foundation

/// The localized button and message text shown by
/// ``BrowserExternalNavigationPresenter`` when it asks whether to open a link in
/// another app or reports that a link could not be opened.
///
/// The strings live in a value type rather than being resolved inside the
/// package because `String(localized:)` binds to the *package* bundle when
/// called from package code, which lacks the app's `Localizable.xcstrings`
/// catalog and would silently drop every non-English translation. The
/// executable app target resolves each key against its own catalog and injects
/// the resulting `BrowserExternalNavigationStrings` into the presenter, so the
/// wire-visible alert copy stays fully localized.
public struct BrowserExternalNavigationStrings: Sendable {
    /// Title of the "open in another app?" confirmation alert.
    public let openPromptTitle: String

    /// Body of the "open in another app?" confirmation alert.
    public let openPromptMessage: String

    /// Title of the confirm button that opens the link in the external app.
    public let openPromptOpenAppButton: String

    /// Title of the cancel button that keeps the user in the browser.
    public let openPromptStayInBrowserButton: String

    /// Title of the "could not open link" failure alert.
    public let openFailureTitle: String

    /// Body of the "could not open link" failure alert.
    public let openFailureMessage: String

    /// Title of the default acknowledgement button on the failure alert.
    public let okButton: String

    /// Title of the failure-alert button that copies the link to the pasteboard.
    public let copyLinkButton: String

    /// Creates a strings bundle for the external-navigation alerts.
    ///
    /// - Parameters:
    ///   - openPromptTitle: Title of the open-in-another-app confirmation alert.
    ///   - openPromptMessage: Body of the open-in-another-app confirmation alert.
    ///   - openPromptOpenAppButton: Confirm button that opens the external app.
    ///   - openPromptStayInBrowserButton: Cancel button that stays in the browser.
    ///   - openFailureTitle: Title of the could-not-open-link failure alert.
    ///   - openFailureMessage: Body of the could-not-open-link failure alert.
    ///   - okButton: Default acknowledgement button on the failure alert.
    ///   - copyLinkButton: Failure-alert button that copies the link.
    public init(
        openPromptTitle: String,
        openPromptMessage: String,
        openPromptOpenAppButton: String,
        openPromptStayInBrowserButton: String,
        openFailureTitle: String,
        openFailureMessage: String,
        okButton: String,
        copyLinkButton: String
    ) {
        self.openPromptTitle = openPromptTitle
        self.openPromptMessage = openPromptMessage
        self.openPromptOpenAppButton = openPromptOpenAppButton
        self.openPromptStayInBrowserButton = openPromptStayInBrowserButton
        self.openFailureTitle = openFailureTitle
        self.openFailureMessage = openFailureMessage
        self.okButton = okButton
        self.copyLinkButton = copyLinkButton
    }
}
