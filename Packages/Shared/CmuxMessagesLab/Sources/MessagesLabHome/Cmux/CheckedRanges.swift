// cmux: range and index checks for the NSString and NSAttributedString calls that raise NSRangeException on a value
// past the end (p10-stability-169). Swift `try` does not catch an Objective-C exception, so a stale range from an
// older text ends the process. These are CmuxNextCompat's CheckedFoundation.swift helpers (p10-stability-166) for
// this module, which cannot depend on the app package: a bad value gives nil, never a clamped value, and the caller
// decides what that means. Bind the checked value, then pass it on (`if let r = s.checkedRange(r0) { ... }`): the
// crash ratchet's objc_raises report counts a call only when its range is not proven that way. Not a vendored file.
import Foundation

extension NSRange {
    /// Whether the range starts and ends within 0 ... `length`. `NSNotFound` and negative fields are outside.
    fileprivate func isInside(length total: Int) -> Bool {
        location >= 0 && length >= 0 && location <= total && length <= total - location
    }
}

extension NSString {
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
        guard let range = checkedRange(range) else { return nil }
        return substring(with: range)
    }

    /// The UTF-16 unit at `index`, or nil when `index` is outside the string (`character(at:)` would raise).
    func checkedCharacter(at index: Int) -> unichar? {
        guard let index = checkedIndex(index) else { return nil }
        return character(at: index)
    }
}

extension NSAttributedString {
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
        guard let range = checkedRange(range) else { return nil }
        return attributedSubstring(from: range)
    }

    /// The value of attribute `name` at `location`, or nil when it has none or `location` is outside the string
    /// (`attribute(_:at:effectiveRange:)` would raise).
    func checkedAttribute(_ name: NSAttributedString.Key, at location: Int) -> Any? {
        guard let location = checkedIndex(location) else { return nil }
        // SAFETY: the effective-range pointer is nil, so Foundation writes no range.
        return unsafe attribute(name, at: location, effectiveRange: nil)
    }

    /// The attributes at `location`, or nil when `location` is outside the string
    /// (`attributes(at:effectiveRange:)` would raise).
    func checkedAttributes(at location: Int) -> [NSAttributedString.Key: Any]? {
        guard let location = checkedIndex(location) else { return nil }
        // SAFETY: the effective-range pointer is nil, so Foundation writes no range.
        return unsafe attributes(at: location, effectiveRange: nil)
    }
}
