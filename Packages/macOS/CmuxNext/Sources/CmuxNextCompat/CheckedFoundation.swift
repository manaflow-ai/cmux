public import Foundation

// Foundation calls that raise an Objective-C exception on a bad argument, behind checks that report it instead.
//
// Swift `try` does not catch an Objective-C exception: `JSONSerialization.data(withJSONObject:)` given a value
// JSON cannot carry (a `Date`, a non-string key, NaN) raises `NSInvalidArgumentException`, and an `NSString` or
// `NSAttributedString` call given a range or index past its UTF-16 length raises `NSRangeException`. Either one
// ends the process. `crash_ratchet.py --report objc_raises` lists the raw calls (queue Q19, p10-stability-166);
// these helpers are their replacements. They never clamp: a bad value is a typed error or nil, and the caller
// decides what that means.

/// JSON writing that throws instead of raising: the value is checked with `isValidJSONObject` before
/// `JSONSerialization` sees it.
public struct CheckedJSON: Sendable {
    /// Why a value could not be written as JSON.
    public enum Failure: Error, Equatable, Sendable {
        /// The value holds something JSON cannot carry: a type other than a string, number, bool, array,
        /// dictionary or `NSNull`, a non-string dictionary key, NaN or an infinity, or a top-level scalar
        /// without `.fragmentsAllowed`.
        case notAJSONObject
        /// `JSONSerialization` returned an error for a valid value; the text is the error's description.
        case serialization(String)
    }

    /// The writing options every ``data(_:)`` call passes to `JSONSerialization`.
    public let options: JSONSerialization.WritingOptions

    public init(options: JSONSerialization.WritingOptions = []) {
        self.options = options
    }

    /// `object` as JSON data, or ``Failure/notAJSONObject`` when `JSONSerialization` would raise on it.
    public func data(_ object: Any) throws(Failure) -> Data {
        // isValidJSONObject wants a container at the top; with .fragmentsAllowed a scalar is valid too.
        let checked: Any = options.contains(.fragmentsAllowed) ? [object] : object
        guard JSONSerialization.isValidJSONObject(checked) else { throw Failure.notAJSONObject }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: options)
        } catch {
            throw Failure.serialization(String(describing: error))
        }
    }
}

/// Range and index checks for `NSString`: each returns nil when the value is outside the string, never a clamped one.
public extension NSString {
    /// `range` when it lies inside the string's UTF-16 length (an empty range at the end included), else nil.
    func checkedRange(_ range: NSRange) -> NSRange? {
        range.isInside(length: length) ? range : nil
    }

    /// `index` when it names a UTF-16 unit of the string (0 ..< length), else nil.
    func checkedIndex(_ index: Int) -> Int? {
        index >= 0 && index < length ? index : nil
    }

    /// The text in `range`, or nil when `range` is outside the string (`substring(with:)` would raise).
    func checkedSubstring(_ range: NSRange) -> String? {
        checkedRange(range).map { substring(with: $0) }
    }

    /// The UTF-16 unit at `index`, or nil when `index` is outside the string (`character(at:)` would raise).
    func checkedCharacter(at index: Int) -> unichar? {
        checkedIndex(index).map { character(at: $0) }
    }
}

/// Range and index checks for `NSAttributedString` (and so `NSMutableAttributedString` and `NSTextStorage`):
/// bind the checked value, then pass it to `attribute(_:at:effectiveRange:)`, `addAttribute(_:value:range:)` or
/// `replaceCharacters(in:with:)`.
public extension NSAttributedString {
    /// `range` when it lies inside the string's UTF-16 length (an empty range at the end included), else nil.
    func checkedRange(_ range: NSRange) -> NSRange? {
        range.isInside(length: length) ? range : nil
    }

    /// `index` when it names a UTF-16 unit of the string (0 ..< length), else nil.
    func checkedIndex(_ index: Int) -> Int? {
        index >= 0 && index < length ? index : nil
    }

    /// The attributed text in `range`, or nil when `range` is outside the string
    /// (`attributedSubstring(from:)` would raise).
    func checkedAttributedSubstring(_ range: NSRange) -> NSAttributedString? {
        checkedRange(range).map { attributedSubstring(from: $0) }
    }
}

extension NSRange {
    /// Whether the range starts and ends within 0 ... `length`. `NSNotFound` and negative fields are outside.
    func isInside(length: Int) -> Bool {
        location >= 0 && self.length >= 0 && location <= length && self.length <= length - location
    }
}
