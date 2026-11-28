/// Why the Chromium engine cannot open a tab, typed for diagnostics
/// (`debug.cef`) and for the WebKit fallback notice.
public nonisolated enum CEFUnavailableReason: Equatable, Sendable {
    /// The runtime was not embedded in this app bundle (fleet and CI builds
    /// have no CEF artifact).
    case notBundled
    /// Loading the framework or `CefInitialize` failed; the message says why.
    case startFailed(String)
    /// CEF shut down (the app is quitting); it cannot start again.
    case shutDown

    /// Stable code for diagnostics: `notBundled`, `startFailed`, `shutDown`.
    public var code: String {
        switch self {
        case .notBundled: "notBundled"
        case .startFailed: "startFailed"
        case .shutDown: "shutDown"
        }
    }

    /// The failure message for `startFailed`.
    public var detail: String? {
        if case .startFailed(let message) = self { return message }
        return nil
    }
}
