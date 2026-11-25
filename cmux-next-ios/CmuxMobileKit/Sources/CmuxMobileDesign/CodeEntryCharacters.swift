import Foundation
#if os(iOS)
import UIKit
#endif

/// The characters a ``CodeBoxes`` field accepts, and how it normalizes what is
/// typed, pasted or autofilled into it.
///
/// Email sign-in codes are six ASCII letters and digits (`FWT88N`): Stack Auth
/// generates them lowercase and the email shows them uppercase. The field shows
/// them uppercase, and `CmuxAuthRuntime` lowercases them before it verifies,
/// so the case the user types never matters. The keyboard follows the set
/// (``keyboard``), so a field can never show a number pad for a code with
/// letters in it.
///
/// ```swift
/// CodeEntryCharacters.alphanumeric.normalized("fwt-88n", length: 6) // "FWT88N"
/// ```
public enum CodeEntryCharacters: Sendable, Equatable {
    /// ASCII digits only (`0`-`9`).
    case digits
    /// ASCII letters and digits; letters become uppercase.
    case alphanumeric

    /// Normalizes raw field text to at most `length` accepted characters.
    ///
    /// Characters outside the set (spaces, dashes, non-ASCII letters) drop out
    /// before letters are uppercased, so `ß` never turns into `SS`. When the text
    /// holds more accepted characters than fit (a pasted "Your code is FWT88N"),
    /// the last whitespace-separated word with exactly `length` accepted
    /// characters wins; otherwise the text is cut to `length`.
    /// - Parameters:
    ///   - raw: The field text after an edit, paste or autofill.
    ///   - length: The number of boxes.
    /// - Returns: The normalized code, at most `length` characters.
    public func normalized(_ raw: String, length: Int) -> String {
        let all = accepted(raw)
        guard all.count > length else { return all }
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if let word = words.reversed().map({ accepted(String($0)) }).first(where: { $0.count == length }) {
            return word
        }
        return String(all.prefix(length))
    }

    /// Whether the set has letters, so the field needs a keyboard with letters.
    public var hasLetters: Bool { self == .alphanumeric }

    #if os(iOS)
    /// The keyboard for this set: a number pad for digits, an ASCII keyboard
    /// for letters and digits.
    public var keyboard: UIKeyboardType { hasLetters ? .asciiCapable : .numberPad }
    #endif

    private func accepted(_ raw: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 48...57:
                result.append(scalar)
            case 65...90 where self == .alphanumeric:
                result.append(scalar)
            case 97...122 where self == .alphanumeric:
                if let upper = Unicode.Scalar(scalar.value - 32) { result.append(upper) }
            default:
                continue
            }
        }
        return String(result)
    }
}
