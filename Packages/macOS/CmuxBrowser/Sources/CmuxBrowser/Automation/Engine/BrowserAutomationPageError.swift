public import Foundation

/// A failure of one browser automation page operation, engine-neutral.
public enum BrowserAutomationPageError: Error, Equatable, Sendable {
    /// The script threw or could not be compiled. The message is the
    /// engine's exception text (for example `ReferenceError: x is not defined`).
    case javaScript(String)
    /// The page has no live engine page (closed, crashed, or never created).
    /// The reason is the engine's when the engine itself cannot run (for
    /// example its runtime failed to start), nil when only this page is gone.
    case pageUnavailable(BrowserEngineUnavailableReason?)
    /// The engine does not implement the named operation.
    case unsupported(String)
    /// The engine answered with something that could not be decoded.
    case malformedResponse(String)
    /// The engine refused or failed the operation for another reason.
    case engine(String)

    /// Human-readable text for socket error payloads.
    public var message: String {
        switch self {
        case .javaScript(let message):
            return message
        case .pageUnavailable(let reason):
            let sentence = String(
                localized: "browser.automation.error.pageUnavailable",
                defaultValue: "The browser page is not available",
                bundle: .module
            )
            // The reason code is a protocol term, kept verbatim so a script
            // reading only the message still sees why.
            return reason.map { "\(sentence) (\($0.code))" } ?? sentence
        case .unsupported(let operation):
            // The operation is a protocol term (for example "trusted key
            // input"), kept verbatim after the localized sentence.
            return String(
                localized: "browser.automation.error.unsupported",
                defaultValue: "This browser engine does not support the operation",
                bundle: .module
            ) + ": " + operation
        case .malformedResponse(let detail):
            return String(
                localized: "browser.automation.error.malformedResponse",
                defaultValue: "The browser engine returned an unreadable response",
                bundle: .module
            ) + ": " + detail
        case .engine(let message):
            return message
        }
    }
}
