// Number and Boolean formats of a Linux Logger value (Logger+Linux.swift).

#if !canImport(os)
internal import Foundation

/// How an interpolated integer is written (`os.OSLogIntegerFormatting`).
public struct OSLogIntegerFormatting: Sendable {
    let radix: Int
    let explicitPositiveSign: Bool
    let includePrefix: Bool
    let uppercase: Bool
    let minDigits: Int

    /// Decimal digits.
    public static let decimal = OSLogIntegerFormatting(radix: 10, explicitPositiveSign: false, includePrefix: false, uppercase: false, minDigits: 0)
    /// Lowercase hexadecimal digits, no prefix.
    public static let hex = OSLogIntegerFormatting(radix: 16, explicitPositiveSign: false, includePrefix: false, uppercase: false, minDigits: 0)
    /// Octal digits, no prefix.
    public static let octal = OSLogIntegerFormatting(radix: 8, explicitPositiveSign: false, includePrefix: false, uppercase: false, minDigits: 0)

    public static func decimal(explicitPositiveSign: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 10, explicitPositiveSign: explicitPositiveSign, includePrefix: false, uppercase: false, minDigits: minDigits)
    }

    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 16, explicitPositiveSign: explicitPositiveSign, includePrefix: includePrefix, uppercase: uppercase, minDigits: minDigits)
    }

    public static func octal(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 8, explicitPositiveSign: explicitPositiveSign, includePrefix: includePrefix, uppercase: uppercase, minDigits: minDigits)
    }

    func format<T: BinaryInteger>(_ number: T) -> String {
        let digits = String(number.magnitude, radix: radix, uppercase: uppercase)
        let padded = String(repeating: "0", count: max(0, minDigits - digits.count)) + digits
        let prefix = includePrefix ? (radix == 16 ? (uppercase ? "0X" : "0x") : radix == 8 ? "0" : "") : ""
        let sign = number < 0 ? "-" : explicitPositiveSign ? "+" : ""
        return sign + prefix + padded
    }
}

/// How an interpolated floating-point number is written (`os.OSLogFloatFormatting`): printf's `%f`, `%e` or
/// `%g`.
public struct OSLogFloatFormatting: Sendable {
    let conversion: Character
    let precision: Int?
    let explicitPositiveSign: Bool
    let uppercase: Bool

    /// `%f`.
    public static let fixed = OSLogFloatFormatting(conversion: "f", precision: nil, explicitPositiveSign: false, uppercase: false)
    /// `%e`.
    public static let exponential = OSLogFloatFormatting(conversion: "e", precision: nil, explicitPositiveSign: false, uppercase: false)
    /// `%g`.
    public static let hybrid = OSLogFloatFormatting(conversion: "g", precision: nil, explicitPositiveSign: false, uppercase: false)

    public static func fixed(precision: Int? = nil, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        OSLogFloatFormatting(conversion: "f", precision: precision, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }

    public static func exponential(precision: Int? = nil, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        OSLogFloatFormatting(conversion: "e", precision: precision, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }

    public static func hybrid(precision: Int? = nil, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        OSLogFloatFormatting(conversion: "g", precision: precision, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }

    func format(_ number: Double) -> String {
        let sign = explicitPositiveSign ? "+" : ""
        let precisionText = precision.map { ".\(max(0, $0))" } ?? ""
        let conversionText = uppercase ? String(conversion).uppercased() : String(conversion)
        return String(format: "%\(sign)\(precisionText)\(conversionText)", number)
    }
}

/// How an interpolated Boolean is written (`os.OSLogBoolFormat`).
public struct OSLogBoolFormat: Sendable {
    let words: (yes: String, no: String)

    /// `true` or `false`.
    public static let truth = OSLogBoolFormat(words: ("true", "false"))
    /// `YES` or `NO`.
    public static let answer = OSLogBoolFormat(words: ("YES", "NO"))
}
#endif
