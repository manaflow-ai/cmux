import Foundation

extension BrowserChromeView {
    /// Runs the certificate warning page's buttons through the action
    /// registry (`browser.certificateWarning.*`), so a click and the action
    /// take one path. The App installs it; true when the action ran.
    public var certificateWarningRouter: ((CertificateWarningCommand) -> Bool)? {
        get { pageStatus.certificateWarningRouter }
        set { pageStatus.certificateWarningRouter = newValue }
    }

    /// The crash page's Reload All Tabs through the registry (`browser.crashPage.reloadAllTabs`); true when it ran.
    public var crashPageReloadAllRouter: (() -> Bool)? { get { pageStatus.reloadAllRouter } set { pageStatus.reloadAllRouter = newValue } }
}
