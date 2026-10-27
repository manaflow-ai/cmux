internal import Foundation

/// JSON writing that throws instead of raising: this package's copy of CmuxNextCompat's `CheckedJSON`
/// (CheckedFoundation.swift, p10-stability-166), with the same API, because an iOS package cannot depend on
/// the macOS one. `JSONSerialization.data(withJSONObject:options:)` raises an Objective-C exception, which
/// Swift cannot catch, for a value JSON cannot carry; Chromium's `base::JSONWriter::WriteWithOptions`
/// (base/json/json_writer.cc) returns false for such a value instead.
struct CheckedJSON: Sendable {
    /// Why a value could not be written as JSON.
    enum Failure: Error, Equatable, Sendable {
        /// The value holds something JSON cannot carry: a type other than a string, number, bool, array,
        /// dictionary or `NSNull`, a non-string dictionary key, NaN or an infinity, or a top-level scalar
        /// without `.fragmentsAllowed`.
        case notAJSONObject
        /// `JSONSerialization` returned an error for a valid value; the text is the error's description.
        case serialization(String)
    }

    /// The writing options every ``data(_:)`` call passes to `JSONSerialization`.
    let options: JSONSerialization.WritingOptions

    init(options: JSONSerialization.WritingOptions = []) {
        self.options = options
    }

    /// `object` as JSON data, or ``Failure/notAJSONObject`` when `JSONSerialization` would raise on it.
    func data(_ object: Any) throws(Failure) -> Data {
        // isValidJSONObject wants a container at the top: a fragment is valid when it is valid inside an array.
        let fragments = options.contains(.fragmentsAllowed)
        guard !fragments || JSONSerialization.isValidJSONObject([object]) else { throw .notAJSONObject }
        guard fragments || JSONSerialization.isValidJSONObject(object) else { throw .notAJSONObject }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: options)
        } catch {
            throw .serialization(String(describing: error))
        }
    }
}
