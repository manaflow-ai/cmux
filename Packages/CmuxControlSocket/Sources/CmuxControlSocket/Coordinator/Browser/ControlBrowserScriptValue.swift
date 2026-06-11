/// A JavaScript evaluation result bridged into a `Sendable` value, preserving
/// the legacy distinction between JS `undefined` (the controller's
/// `V2BrowserUndefinedSentinel`) and every other value (already normalized by
/// the legacy `v2NormalizeJSValue` rules and bridged to ``JSONValue``).
public enum ControlBrowserScriptValue: Sendable, Equatable {
    /// The script evaluated to JS `undefined` (the legacy sentinel case).
    case undefined
    /// The script evaluated to a value (JS `null` arrives as
    /// ``JSONValue/null``).
    case value(JSONValue)

    /// The legacy eval-envelope type key (`__cmux_t`), used when re-encoding
    /// `undefined` into the wire payload exactly as `v2NormalizeJSValue` did.
    public static let envelopeTypeKey = "__cmux_t"
    /// The legacy eval-envelope value key (`__cmux_v`).
    public static let envelopeValueKey = "__cmux_v"
    /// The legacy eval-envelope `undefined` type tag.
    public static let envelopeTypeUndefined = "undefined"
}
