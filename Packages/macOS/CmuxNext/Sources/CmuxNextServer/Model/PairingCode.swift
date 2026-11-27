public import Foundation

/// Pairing code rules: 8 Crockford base32 symbols (40 bits), shown as
/// `XXXX-XXXX`, case insensitive, `O` reads as `0` and `I`/`L` as `1`.
public nonisolated enum PairingCode {
    public static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 8

    /// `7KQ4M2XD` -> `7KQ4-M2XD`. Other lengths are returned unchanged.
    public static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        return String(code.prefix(4)) + "-" + String(code.suffix(4))
    }

    /// Canonical symbols of what a person typed: uppercase, separators
    /// dropped, `O`->`0`, `I`/`L`->`1`. Symbols outside the alphabet stay,
    /// so `isComplete` can refuse them.
    public static func normalize(_ input: String) -> String {
        var out = ""
        for character in input.uppercased() {
            switch character {
            case "-", " ", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: out.append(character)
            }
        }
        return out
    }

    /// Whether `input` normalizes to a full valid code.
    public static func isComplete(_ input: String) -> Bool {
        let code = normalize(input)
        return code.count == length && code.allSatisfy { alphabet.contains($0) }
    }

    /// What the code field shows while typing: normalized, at most 8
    /// symbols, a dash after the fourth.
    public static func editing(_ input: String) -> String {
        let code = String(normalize(input).filter { alphabet.contains($0) }.prefix(length))
        guard code.count > 4 else { return code }
        return String(code.prefix(4)) + "-" + String(code.dropFirst(4))
    }

    /// The QR payload: a universal link with the code in the query and the
    /// key fingerprint in the fragment (never sent to a web server).
    public static func payload(code: String, fingerprint: String) -> String {
        "https://cmux.com/pair?c=\(normalize(code))#fp=\(fingerprint)"
    }
}
