import Foundation

/// The engine that renders a browser panel's page.
///
/// A panel's engine is fixed when the panel is created. Reopening a page in
/// the other engine creates a new panel with the same URL. The raw values are
/// the values of the `browser.engine` setting and the CLI `--engine` option.
public enum BrowserEngineKind: String, CaseIterable, Hashable, Sendable, Codable {
    /// Apple WebKit (`WKWebView`), the default engine.
    case webkit
    /// Chromium through the embedded CEF runtime, available only when the
    /// runtime is bundled with the app.
    case chromium

    /// Parses a user- or automation-supplied engine name.
    ///
    /// Accepts the raw values plus the aliases `safari` (WebKit), `cef` and
    /// `chrome` (Chromium), case-insensitively and ignoring surrounding
    /// whitespace.
    /// - Parameter requestValue: The requested engine name, or `nil`.
    /// - Returns: The named engine, or `nil` when the value names none.
    public init?(requestValue: String?) {
        guard let value = requestValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        switch value {
        case "webkit", "safari":
            self = .webkit
        case "chromium", "cef", "chrome":
            self = .chromium
        default:
            return nil
        }
    }

    /// The name of the environment variable that forces every new browser
    /// panel onto one engine (test harnesses run suites per engine with it).
    public static let environmentVariableName = "CMUX_BROWSER_ENGINE"

    /// The engine `CMUX_BROWSER_ENGINE` names in `environment`.
    /// - Parameter environment: A process environment, usually
    ///   `ProcessInfo.processInfo.environment`.
    /// - Returns: The named engine, or `nil` when the variable is unset or
    ///   names no engine.
    public static func environmentOverride(_ environment: [String: String]) -> BrowserEngineKind? {
        BrowserEngineKind(requestValue: environment[environmentVariableName])
    }
}
