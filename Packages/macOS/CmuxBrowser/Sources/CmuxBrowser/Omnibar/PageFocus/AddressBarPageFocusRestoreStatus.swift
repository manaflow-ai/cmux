import Foundation

/// Outcome of one attempt to restore page input focus after the omnibar closes.
///
/// The values map one-to-one onto the status strings returned by the
/// restore JavaScript (`restored`, `no_state`, `missing_target`, `not_focused`,
/// `error`). The repository retries only on `notFocused` or `error`.
public enum AddressBarPageFocusRestoreStatus: String, Sendable {
    /// The previously focused editable element was re-focused successfully.
    case restored
    /// No captured focus state exists, so nothing needs restoring.
    case noState = "no_state"
    /// Captured state existed but its target element is no longer in the DOM.
    case missingTarget = "missing_target"
    /// The element was found but did not become the document's active element.
    case notFocused = "not_focused"
    /// The script threw, returned a non-string, or evaluation itself failed.
    case error

    /// Classifies a WebKit evaluation result into a restore status.
    ///
    /// Any evaluation error, or a non-string / unrecognized payload, collapses
    /// to ``error`` so the caller's retry logic stays simple.
    ///
    /// - Parameters:
    ///   - result: The raw value returned by the JavaScript evaluation.
    ///   - error: Any error WebKit surfaced for the evaluation.
    /// - Returns: The mapped restore status.
    public static func from(result: Any?, error: (any Error)?) -> AddressBarPageFocusRestoreStatus {
        if error != nil { return .error }
        guard let raw = result as? String else { return .error }
        return AddressBarPageFocusRestoreStatus(rawValue: raw) ?? .error
    }
}
