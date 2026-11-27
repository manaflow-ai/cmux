import Foundation

/// Wire-format constants for the `browser eval` undefined/value envelope.
///
/// When a page-world script returns `undefined`, WebKit collapses it to `nil`,
/// which is indistinguishable from a script that returned JSON `null`. The
/// browser eval path therefore wraps every result in a small JSON object whose
/// `typeKey` is either `typeUndefined` or `typeValue`, with the real payload (for
/// the value case) under `valueKey`. ``BrowserControlService/normalizeJSValue(_:isUndefinedSentinel:)``
/// re-materializes the `undefined` sentinel back into this envelope shape so the
/// RPC reply distinguishes the two.
///
/// The default values are the exact strings the cmux v2 browser RPC wire format
/// has always used; do not change them without a coordinated protocol bump.
public struct BrowserEvalEnvelope: Sendable, Equatable {
    /// JSON key carrying the envelope discriminator (`typeUndefined` or `typeValue`).
    public let typeKey: String
    /// JSON key carrying the real value when the discriminator is `typeValue`.
    public let valueKey: String
    /// Discriminator value indicating the script produced JavaScript `undefined`.
    public let typeUndefined: String
    /// Discriminator value indicating the script produced a concrete value.
    public let typeValue: String

    /// Creates an envelope descriptor.
    /// - Parameters:
    ///   - typeKey: JSON key for the discriminator. Defaults to the wire value `"__cmux_t"`.
    ///   - valueKey: JSON key for the payload. Defaults to the wire value `"__cmux_v"`.
    ///   - typeUndefined: discriminator for `undefined`. Defaults to `"undefined"`.
    ///   - typeValue: discriminator for a concrete value. Defaults to `"value"`.
    public init(
        typeKey: String = "__cmux_t",
        valueKey: String = "__cmux_v",
        typeUndefined: String = "undefined",
        typeValue: String = "value"
    ) {
        self.typeKey = typeKey
        self.valueKey = valueKey
        self.typeUndefined = typeUndefined
        self.typeValue = typeValue
    }
}
