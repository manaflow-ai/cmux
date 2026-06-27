public import Foundation

/// Lenient coercion reads over an untyped JSON scalar.
///
/// These complement ``JSONScalar``'s strict narrowing (which rejects numeric
/// booleans, fractional or string integers, and untrimmed strings). The cmux
/// socket-snapshot wire format is looser than the settings file: it can send a
/// boolean as a numeric `0`/`1`, a process id as a decimal string, and pad
/// identifiers with surrounding whitespace. These accessors reproduce that
/// tolerant coercion byte-for-byte, so they are deliberately separate members
/// rather than a relaxation of the strict ``JSONScalar/bool`` / ``JSONScalar/int``.
extension JSONScalar {
    /// The value as a trimmed, non-empty `String`, or `nil`.
    ///
    /// Leading and trailing whitespace and newlines are trimmed; an empty or
    /// all-whitespace string yields `nil`.
    public var nonEmptyString: String? {
        guard let value = rawValue as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The value as a `UUID` parsed from its ``nonEmptyString`` form, or `nil`.
    public var uuid: UUID? {
        guard let value = nonEmptyString else { return nil }
        return UUID(uuidString: value)
    }

    /// The value coerced to a `Bool`, defaulting to `false`.
    ///
    /// Accepts a Swift `Bool` or any `NSNumber` (a zero number is `false`, any
    /// non-zero number is `true`). Unlike ``JSONScalar/bool``, a numeric value
    /// is coerced rather than rejected.
    public var coercedBool: Bool {
        if let value = rawValue as? Bool { return value }
        if let value = rawValue as? NSNumber { return value.boolValue }
        return false
    }

    /// The value coerced to an `Int`, or `nil`.
    ///
    /// Accepts a Swift `Int`, any `NSNumber` (truncating toward zero via
    /// `intValue`), or a decimal `String` (after trimming whitespace). Unlike
    /// ``JSONScalar/int``, fractional numbers and booleans are not rejected and
    /// strings are parsed.
    public var coercedInt: Int? {
        if let value = rawValue as? Int { return value }
        if let value = rawValue as? NSNumber { return value.intValue }
        if let value = rawValue as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// The value coerced to `[Int]`.
    ///
    /// A homogeneous `[Int]` is returned as-is; otherwise a heterogeneous
    /// `[Any]` is mapped element-by-element through ``coercedInt`` (dropping
    /// elements that do not coerce), and any non-array value yields `[]`.
    public var coercedIntArray: [Int] {
        if let values = rawValue as? [Int] { return values }
        guard let values = rawValue as? [Any] else { return [] }
        return values.compactMap { JSONScalar($0).coercedInt }
    }
}
