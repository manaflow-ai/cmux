import Foundation

/// Errors raised by browser engines and pages.
public enum BrowserEngineError: Error, Equatable, Hashable, Sendable {
    /// The engine cannot create pages.
    case unavailable(BrowserEngineKind, BrowserEngineUnavailableReason)
    /// The engine does not support the named operation. Check
    /// ``BrowserPage/capabilities`` before calling.
    case unsupported(String)
    /// The page was closed.
    case pageClosed
    /// A script threw; the associated value is the error message.
    case javaScript(String)
}
