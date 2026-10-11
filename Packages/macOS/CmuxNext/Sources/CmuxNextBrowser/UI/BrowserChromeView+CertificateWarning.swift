import Foundation

extension BrowserChromeView {
    /// Runs the certificate warning page's buttons through the action
    /// registry (`browser.certificateWarning.*`), so a click and the action
    /// take one path. The App installs it; true when the action ran.
    public var certificateWarningRouter: ((CertificateWarningCommand) -> Bool)? {
        get { pageStatus.certificateWarningRouter }
        set { pageStatus.certificateWarningRouter = newValue }
    }
}
