public import Foundation

/// Why ``CheckedJSON`` did not write an object.
public enum CheckedJSONError: Error, Equatable, Sendable {
    /// The object holds a value JSON cannot hold (a `Date`, a `URL`, NaN or infinity, a non-string
    /// dictionary key, ...), or its top level is not an array or a dictionary and the options do not
    /// have `.fragmentsAllowed`. `JSONSerialization.data(withJSONObject:options:)` raises an
    /// Objective-C exception for such an object, which Swift cannot catch: the process ends.
    case invalidJSONObject(topLevelType: String)
    /// `JSONSerialization` threw for an object it accepted as valid.
    case writeFailed(String)
}

/// JSON writing that reports an object JSON cannot hold as a thrown error instead of the
/// Objective-C exception `JSONSerialization.data(withJSONObject:options:)` raises for it.
///
/// Chromium's `base::JSONWriter::WriteWithOptions` (base/json/json_writer.cc) returns false for a
/// value it cannot write (a binary value) instead of crashing; this is the same contract over
/// `JSONSerialization`, which has no non-raising write. Write every `[String: Any]` / `[Any]`
/// payload through ``data(withJSONObject:options:)``; prefer `JSONEncoder` for `Codable` values.
public struct CheckedJSON {
    /// The writing options for ``data(_:)``.
    public let options: JSONSerialization.WritingOptions

    public init(options: JSONSerialization.WritingOptions = []) {
        self.options = options
    }

    /// Whether `object` can be written with these options without an Objective-C exception.
    public func isValid(_ object: Any) -> Bool {
        // isValidJSONObject wants an array or a dictionary at the top; a fragment is valid when
        // it is valid as the one element of an array.
        options.contains(.fragmentsAllowed)
            ? JSONSerialization.isValidJSONObject([object])
            : JSONSerialization.isValidJSONObject(object)
    }

    /// The JSON for `object`, or ``CheckedJSONError`` when JSON cannot hold it.
    public func data(_ object: Any) throws(CheckedJSONError) -> Data {
        guard isValid(object) else {
            throw .invalidJSONObject(topLevelType: String(describing: type(of: object)))
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: options)
        } catch {
            throw .writeFailed(String(describing: error))
        }
    }

    /// The JSON for `object` written with `options`, or ``CheckedJSONError`` when JSON cannot hold
    /// it. The checked replacement for `JSONSerialization.data(withJSONObject:options:)`.
    public static func data(
        withJSONObject object: Any,
        options: JSONSerialization.WritingOptions = []
    ) throws(CheckedJSONError) -> Data {
        try CheckedJSON(options: options).data(object)
    }
}
