/// DOM error names surfaced back to the page world when a passkey request fails.
///
/// The raw values are the exact `DOMException`/`TypeError` names the browser
/// shim reconstructs on the JavaScript side.
public enum BrowserWebAuthnErrorName: String, Sendable {
    case invalidState = "InvalidStateError"
    case notAllowed = "NotAllowedError"
    case notSupported = "NotSupportedError"
    case security = "SecurityError"
    case type = "TypeError"
    case unknown = "UnknownError"
}
