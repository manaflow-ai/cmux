internal import Foundation

/// Why ``CheckedJSON`` did not write an object.
enum CheckedJSONError: Error, Equatable, Sendable {
    /// The object holds a value JSON cannot hold (a `Date`, NaN or infinity, a non-string dictionary
    /// key, ...), or its top level is not an array or a dictionary and the options do not have
    /// `.fragmentsAllowed`: `JSONSerialization.data(withJSONObject:options:)` raises an uncatchable
    /// Objective-C exception for it.
    case invalidJSONObject(topLevelType: String)
    /// `JSONSerialization` threw for an object it accepted as valid.
    case writeFailed(String)
}

/// JSON writing that throws for an object JSON cannot hold instead of raising: this package's
/// copy of CmuxNextCompat's `CheckedJSON` (an iOS package cannot depend on the macOS one), with the
/// same contract as Chromium's `base::JSONWriter::WriteWithOptions` (base/json/json_writer.cc),
/// which returns false for a value it cannot write.
struct CheckedJSON {
    let options: JSONSerialization.WritingOptions

    init(options: JSONSerialization.WritingOptions = []) {
        self.options = options
    }

    /// Whether `object` can be written with these options without an Objective-C exception.
    func isValid(_ object: Any) -> Bool {
        options.contains(.fragmentsAllowed)
            ? JSONSerialization.isValidJSONObject([object])
            : JSONSerialization.isValidJSONObject(object)
    }

    /// The JSON for `object`, or ``CheckedJSONError`` when JSON cannot hold it.
    func data(_ object: Any) throws(CheckedJSONError) -> Data {
        guard isValid(object) else {
            throw .invalidJSONObject(topLevelType: String(describing: type(of: object)))
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: options)
        } catch {
            throw .writeFailed(String(describing: error))
        }
    }

    /// The checked replacement for `JSONSerialization.data(withJSONObject:options:)`.
    static func data(
        withJSONObject object: Any,
        options: JSONSerialization.WritingOptions = []
    ) throws(CheckedJSONError) -> Data {
        try CheckedJSON(options: options).data(object)
    }
}
