import Foundation

/// Wire-format constants for the `browser eval` undefined/value envelope.
///
/// When a page-world script returns `undefined`, WebKit collapses it to `nil`,
/// which is indistinguishable from a script that returned JSON `null`. The
/// browser eval path therefore wraps every result in a small JSON object whose
/// `typeKey` is `typeUndefined`, `typeValue`, or `typeError`, with the real
/// payload (for the value case) under `valueKey`. Error envelopes carry a stable
/// code and message so values that cannot cross WebKit never reach response
/// encoding. ``BrowserControlService/normalizeJSValue(_:isUndefinedSentinel:)``
/// re-materializes the `undefined` sentinel back into this envelope shape so the
/// RPC reply preserves the distinction.
///
/// The default values are the exact strings the cmux v2 browser RPC wire format
/// has always used; do not change them without a coordinated protocol bump.
public struct BrowserEvalEnvelope: Sendable, Equatable {
    /// JSON key carrying the envelope discriminator.
    public let typeKey: String
    /// JSON key carrying the real value when the discriminator is `typeValue`.
    public let valueKey: String
    /// Discriminator value indicating the script produced JavaScript `undefined`.
    public let typeUndefined: String
    /// Discriminator value indicating the script produced a concrete value.
    public let typeValue: String
    /// Discriminator value indicating result sanitization failed.
    public let typeError: String
    /// JSON key carrying a stable error code when the discriminator is `typeError`.
    public let errorCodeKey: String
    /// JSON key carrying an error message when the discriminator is `typeError`.
    public let errorMessageKey: String
    /// Error code returned when the evaluated result contains a true cycle.
    public let circularReferenceCode: String
    /// Error message returned when the evaluated result contains a true cycle.
    public let circularReferenceMessage: String

    /// Creates an envelope descriptor.
    /// - Parameters:
    ///   - typeKey: JSON key for the discriminator. Defaults to the wire value `"__cmux_t"`.
    ///   - valueKey: JSON key for the payload. Defaults to the wire value `"__cmux_v"`.
    ///   - typeUndefined: discriminator for `undefined`. Defaults to `"undefined"`.
    ///   - typeValue: discriminator for a concrete value. Defaults to `"value"`.
    ///   - typeError: discriminator for a sanitization failure. Defaults to `"error"`.
    ///   - errorCodeKey: JSON key for an error code. Defaults to `"__cmux_error_code"`.
    ///   - errorMessageKey: JSON key for an error message. Defaults to `"__cmux_error_message"`.
    ///   - circularReferenceCode: stable circular-reference error code.
    ///   - circularReferenceMessage: stable circular-reference error message;
    ///     `nil` uses the localized default.
    public init(
        typeKey: String = "__cmux_t",
        valueKey: String = "__cmux_v",
        typeUndefined: String = "undefined",
        typeValue: String = "value",
        typeError: String = "error",
        errorCodeKey: String = "__cmux_error_code",
        errorMessageKey: String = "__cmux_error_message",
        circularReferenceCode: String = "circular_reference",
        circularReferenceMessage: String? = nil
    ) {
        self.typeKey = typeKey
        self.valueKey = valueKey
        self.typeUndefined = typeUndefined
        self.typeValue = typeValue
        self.typeError = typeError
        self.errorCodeKey = errorCodeKey
        self.errorMessageKey = errorMessageKey
        self.circularReferenceCode = circularReferenceCode
        self.circularReferenceMessage = circularReferenceMessage ?? String(
            localized: "cli.browser.error.circularReference",
            defaultValue: "browser.eval result contains a circular reference"
        )
    }
}
