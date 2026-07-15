public import Foundation

/// Errors shared by browser-engine session implementations.
public enum BrowserEngineSessionError: LocalizedError, Sendable {
    /// The engine returned no screenshot pixels.
    case emptyScreenshot

    /// A Chromium application could not be found.
    case chromiumUnavailable

    /// A Chrome DevTools Protocol operation failed.
    case chromiumProtocol(String)

    /// A Chromium process ended before exposing its DevTools endpoint.
    case chromiumLaunch(String)

    /// A browser returned a JavaScript value that cannot cross the engine boundary.
    case unsupportedJavaScriptValue

    /// A localized, user-facing description that omits protocol internals.
    public var errorDescription: String? {
        switch self {
        case .emptyScreenshot:
            return String(
                localized: "browser.engine.error.emptyScreenshot",
                defaultValue: "The browser returned an empty screenshot."
            )
        case .chromiumUnavailable:
            return String(
                localized: "browser.chromium.error.notInstalled",
                defaultValue: "Chromium is selected, but no supported Chromium browser is installed."
            )
        case .chromiumProtocol:
            return String(
                localized: "browser.chromium.error.operationFailed",
                defaultValue: "Chromium stopped responding. Reload the page or switch to WebKit."
            )
        case .chromiumLaunch:
            return String(
                localized: "browser.chromium.error.launchFailed",
                defaultValue: "Chromium could not start. Try another installed Chromium browser or switch to WebKit."
            )
        case .unsupportedJavaScriptValue:
            return String(
                localized: "browser.engine.error.unsupportedJavaScriptValue",
                defaultValue: "The browser returned an unsupported JavaScript value."
            )
        }
    }
}
