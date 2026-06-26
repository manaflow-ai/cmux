import Foundation

/// A typed view over an untyped JSON scalar (`Any?` as produced by
/// `JSONSerialization`), narrowing it to a Swift value with the exact coercion
/// rules cmux's settings file parser relies on.
///
/// The bridge from JSON is deliberately strict: numbers are only accepted as
/// `NSNumber`, and the JSON booleans `true`/`false` (which `JSONSerialization`
/// represents as `NSNumber` backed by `CFBoolean`) are kept distinct from
/// numeric values via `CFBooleanGetTypeID`. This prevents `true` from being read
/// as the integer `1`, or `1` from being read as the boolean `true`.
public struct JSONScalar {
    /// The untyped value extracted from a parsed JSON object, typically
    /// `dictionary[key]` where `dictionary` is `[String: Any]`.
    public let rawValue: Any?

    /// Wrap an untyped JSON value for typed narrowing.
    public init(_ rawValue: Any?) {
        self.rawValue = rawValue
    }

    /// The value as a `String`, or `nil` if it is not a JSON string.
    public var string: String? {
        rawValue as? String
    }

    /// The value as a `Bool`, or `nil` if it is not a JSON boolean.
    ///
    /// Only `CFBoolean`-backed `NSNumber`s qualify, so a numeric `1`/`0` is
    /// rejected rather than coerced to `true`/`false`.
    public var bool: Bool? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// The value as an `Int`, or `nil` if it is not an integral JSON number.
    ///
    /// JSON booleans are rejected, and a number with a fractional part is
    /// rejected; only values equal to their rounded form are accepted. Uses
    /// `NSNumber.intValue` so out-of-range magnitudes clamp/truncate instead of
    /// trapping the way `Int(Double)` would.
    public var int: Int? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.rounded() == doubleValue else { return nil }
        return number.intValue
    }

    /// The value as a `Double`, or `nil` if it is not a numeric JSON value.
    ///
    /// JSON booleans are rejected so `true` never reads as `1.0`.
    public var double: Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// The value as `[String]`, or `nil` if it is not a JSON array whose every
    /// element is a string. A single non-string element fails the whole array.
    public var stringArray: [String]? {
        guard let values = rawValue as? [Any] else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard let string = value as? String else { return nil }
            strings.append(string)
        }
        return strings
    }
}
