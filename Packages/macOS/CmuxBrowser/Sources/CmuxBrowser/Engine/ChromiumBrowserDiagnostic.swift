public import Foundation

/// A localized failure reason produced by the managed Chromium engine.
///
/// The value is shared with app-side automation so every entry point reports
/// the same diagnosis without exposing a namespace of unrelated strings.
public enum ChromiumBrowserDiagnostic: Error, Equatable, Sendable {
    /// JavaScript evaluation completed without a value envelope.
    case noJavaScriptValue
    /// JavaScript evaluation exceeded the socket deadline.
    case javascriptTimedOut
    /// Screenshot capture returned no image bytes.
    case noScreenshot
    /// Screenshot capture exceeded the socket deadline.
    case screenshotTimedOut
    /// A raw CDP command completed without a result.
    case noCommandResult
    /// A raw CDP command exceeded the socket deadline.
    case commandTimedOut
    /// Document-start script registration exceeded its deadline.
    case documentScriptTimedOut
    /// Chromium returned no stable identifier for a document-start script.
    case malformedDocumentScriptRegistration
    /// Navigation exceeded the socket deadline.
    case navigationTimedOut
    /// An operation ended without success or an explicit failure.
    case operationEnded
    /// Chromium returned an invalid cookie payload.
    case malformedCookies
    /// A caller supplied a cookie that CDP cannot represent.
    case invalidCookiePayload
    /// Discovery found no page-scoped websocket.
    case noPageWebSocket
    /// Discovery found no page target.
    case noPageTarget
    /// The loopback discovery endpoint could not be reached safely.
    case endpointUnavailable
    /// Chromium's renderer exited with a process status.
    case rendererExited(Int32)
    /// A navigation snapshot stream ended before completion.
    case navigationStreamEnded
    /// Chromium returned an invalid navigation-history payload.
    case malformedNavigationHistory
    /// Chromium returned an error without diagnostic text.
    case unknownCDPError
    /// Runtime evaluation failed without exception details.
    case javaScriptEvaluationFailed
    /// Chromium did not expose its endpoint before the startup deadline.
    case startupTimedOut
    /// The page-scoped websocket closed.
    case connectionClosed
    /// A CDP command could not be encoded as JSON.
    case commandEncodingFailed

    /// User-facing localized diagnostic text.
    public var message: String {
        switch self {
        case .noJavaScriptValue:
            return Self.localized("browser.chromium.automation.noJavaScriptValue", "Chromium returned no JavaScript value")
        case .javascriptTimedOut:
            return Self.localized("browser.chromium.automation.javascriptTimedOut", "Timed out waiting for JavaScript result")
        case .noScreenshot:
            return Self.localized("browser.chromium.automation.noScreenshot", "Chromium returned no screenshot")
        case .screenshotTimedOut:
            return Self.localized("browser.chromium.automation.screenshotTimedOut", "Timed out waiting for Chromium screenshot")
        case .noCommandResult:
            return Self.localized("browser.chromium.automation.noCommandResult", "Chromium returned no CDP command result")
        case .commandTimedOut:
            return Self.localized("browser.chromium.automation.commandTimedOut", "Timed out waiting for Chromium CDP command")
        case .documentScriptTimedOut:
            return Self.localized("browser.chromium.automation.documentScriptTimedOut", "Timed out registering Chromium document script")
        case .malformedDocumentScriptRegistration:
            return Self.localized(
                "browser.chromium.automation.malformedDocumentScriptRegistration",
                "Chromium returned a malformed document-script registration"
            )
        case .navigationTimedOut:
            return Self.localized("browser.chromium.automation.navigationTimedOut", "Timed out waiting for Chromium navigation")
        case .operationEnded:
            return Self.localized("browser.chromium.automation.operationEnded", "Chromium operation ended without a result")
        case .malformedCookies:
            return Self.localized("browser.chromium.automation.malformedCookies", "Chromium returned malformed cookies")
        case .invalidCookiePayload:
            return Self.localized("browser.chromium.automation.invalidCookiePayload", "Invalid cookie payload")
        case .noPageWebSocket:
            return Self.localized("browser.chromium.cdp.noPageWebSocket", "Chromium has no page websocket")
        case .noPageTarget:
            return Self.localized("browser.chromium.cdp.noPageTarget", "Chromium has no page target")
        case .endpointUnavailable:
            return Self.localized("browser.chromium.cdp.endpointUnavailable", "CDP endpoint is unavailable")
        case .rendererExited(let status):
            return String.localizedStringWithFormat(
                Self.localized("browser.chromium.cdp.rendererExited", "Chromium renderer exited (%lld)"),
                Int64(status)
            )
        case .navigationStreamEnded:
            return Self.localized("browser.chromium.cdp.navigationStreamEnded", "Chromium navigation stream ended")
        case .malformedNavigationHistory:
            return Self.localized("browser.chromium.cdp.malformedNavigationHistory", "Chromium returned malformed navigation history")
        case .unknownCDPError:
            return Self.localized("browser.chromium.cdp.unknownError", "Unknown CDP error")
        case .javaScriptEvaluationFailed:
            return Self.localized("browser.chromium.cdp.javaScriptEvaluationFailed", "JavaScript evaluation failed")
        case .startupTimedOut:
            return Self.localized("browser.chromium.cdp.startupTimedOut", "Timed out waiting for Chromium")
        case .connectionClosed:
            return Self.localized("browser.chromium.cdp.connectionClosed", "CDP connection closed")
        case .commandEncodingFailed:
            return Self.localized("browser.chromium.cdp.commandEncodingFailed", "Could not encode CDP command")
        }
    }

    private static func localized(
        _ key: StaticString,
        _ defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }
}

extension ChromiumBrowserDiagnostic: LocalizedError {
    /// The localized diagnostic surfaced through Foundation error APIs.
    public var errorDescription: String? { message }
}
