import Foundation

/// Why an engine cannot create pages in this process.
///
/// Used for the WebKit fallback notice, CLI refusals and diagnostics.
public enum BrowserEngineUnavailableReason: Equatable, Hashable, Sendable {
    /// The engine runtime is not part of this app build (for example, a build
    /// made without the Chromium runtime artifact).
    case notBundled
    /// Loading or initializing the runtime failed; the message says why.
    case startFailed(String)
    /// The runtime shut down because the app is quitting; it cannot restart.
    case shutDown

    /// A stable machine-readable code: `notBundled`, `startFailed` or `shutDown`.
    public var code: String {
        switch self {
        case .notBundled: "notBundled"
        case .startFailed: "startFailed"
        case .shutDown: "shutDown"
        }
    }

    /// The failure message for ``startFailed(_:)``, otherwise `nil`.
    public var detail: String? {
        if case .startFailed(let message) = self { return message }
        return nil
    }
}
