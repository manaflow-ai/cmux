/// The validated `browser.import.dialog` scope, mirroring the app's
/// `BrowserImportScope` cases. `rawValue` matches the app enum exactly so the
/// wire payload (`"scope": rawValue`) is byte-identical.
public enum ControlBrowserImportScope: String, Sendable, Equatable {
    /// Cookies only.
    case cookiesOnly
    /// History only.
    case historyOnly
    /// Cookies and history.
    case cookiesAndHistory
    /// Everything.
    case everything
}
