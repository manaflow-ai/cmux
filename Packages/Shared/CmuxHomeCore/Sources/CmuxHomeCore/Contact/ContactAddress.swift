import Foundation

/// An email address or phone number typed into the To: field. Normalized so
/// that two spellings of one address compare equal (and dedupe invites).
public enum ContactAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Lowercased, trimmed.
    case email(String)
    /// E.164: "+" then 8 to 15 digits.
    case phone(String)

    public var description: String {
        switch self {
        case .email(let value), .phone(let value): value
        }
    }

    public var isEmail: Bool { if case .email = self { true } else { false } }

    /// Parses free text. Phone numbers without a country code use
    /// `defaultCallingCode` (for example "1" for the US region).
    /// Returns nil for anything that is not clearly one address.
    public static func parse(_ input: String, defaultCallingCode: String = "1") -> ContactAddress? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 254 else { return nil }
        if trimmed.contains("@") { return parseEmail(trimmed) }
        return parsePhone(trimmed, defaultCallingCode: defaultCallingCode)
    }

    static func parseEmail(_ text: String) -> ContactAddress? {
        let value = text.lowercased()
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let local = pieces[0]
        let domain = pieces[1]
        guard !local.isEmpty, local.count <= 64 else { return nil }
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return nil }
        let allowedLocal = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~-"))
        let allowedDomain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard local.unicodeScalars.allSatisfy(allowedLocal.contains),
              domain.unicodeScalars.allSatisfy(allowedDomain.contains),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return nil }
        let tld = domain.split(separator: ".").last ?? ""
        guard tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return .email(value)
    }

    static func parsePhone(_ text: String, defaultCallingCode: String) -> ContactAddress? {
        let separators = CharacterSet(charactersIn: " ()-./\u{00A0}")
        var hasPlus = false
        var digits = ""
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if scalar == "+" {
                guard index == 0 else { return nil }
                hasPlus = true
            } else if CharacterSet.decimalDigits.contains(scalar), scalar.isASCII {
                digits.unicodeScalars.append(scalar)
            } else if !separators.contains(scalar) {
                return nil
            }
        }
        if !hasPlus {
            if digits.hasPrefix("00") {
                digits.removeFirst(2)
            } else if defaultCallingCode == "1", digits.count == 11, digits.hasPrefix("1") {
                // Already carries the North American country code.
            } else {
                digits = defaultCallingCode + digits
            }
        }
        guard (8...15).contains(digits.count), digits.first != "0" else { return nil }
        if defaultCallingCode == "1", digits.hasPrefix("1"), digits.count != 11 { return nil }
        return .phone("+" + digits)
    }
}

/// Splits a To: field into tokens at commas, semicolons and newlines, and
/// parses each one. Unparseable tokens are returned so the UI can mark them.
public struct ContactFieldParse: Hashable, Sendable {
    public var addresses: [ContactAddress]
    public var invalid: [String]

    public static func parse(_ text: String, defaultCallingCode: String = "1") -> ContactFieldParse {
        var addresses: [ContactAddress] = []
        var invalid: [String] = []
        for token in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let piece = token.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if let address = ContactAddress.parse(piece, defaultCallingCode: defaultCallingCode) {
                if !addresses.contains(address) { addresses.append(address) }
            } else {
                invalid.append(piece)
            }
        }
        return ContactFieldParse(addresses: addresses, invalid: invalid)
    }
}
