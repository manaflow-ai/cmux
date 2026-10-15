import Foundation

/// Why the Chromium engine cannot open a page now.
public enum CEFUnavailableReason: Equatable, Sendable {
    /// The runtime is not embedded in this build (no CEF artifact).
    case notBundled
    /// Mapping the framework or `CefInitialize` failed; the message says why.
    case startFailed(String)
    /// The app is quitting (CEF cannot start again after `CefShutdown`).
    case shutDown

    /// Stable identifier for logs, CLI and socket replies.
    public var code: String {
        switch self {
        case .notBundled: "notBundled"
        case .startFailed: "startFailed"
        case .shutDown: "shutDown"
        }
    }
}

/// Errors of the Chromium engine.
public enum CEFError: Error, Equatable, Sendable {
    case unavailable(CEFUnavailableReason)
    /// The browser closed (or never existed) before the call finished.
    case browserClosed
    /// A DevTools call or reply did not finish in time.
    case timedOut(String)
    /// A DevTools protocol error, or a script that threw; the JSON or message.
    case devTools(String)
}
