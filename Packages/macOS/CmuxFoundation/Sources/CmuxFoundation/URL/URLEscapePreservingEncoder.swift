/// Percent-encodes URL text like a browser, keeping its existing `%XX` escapes.
///
/// `URL(string:)` and `URLComponents(string:)` percent-encode a component
/// that holds characters a URL can't carry, such as raw Unicode, but they
/// treat that whole component as unencoded text. An escape already in it is
/// encoded again, so `会議_2026%2F11` reaches the page as
/// `%E4%BC%9A%E8%AD%B0_2026%252F11`. Browsers encode only the characters
/// that need it. Running the text through ``encode(_:)`` first hands
/// Foundation a component with nothing left to encode, so it stays as given.
///
/// ```swift
/// let text = URLEscapePreservingEncoder().encode("https://example.com/会議_2026%2F11")
/// // "https://example.com/%E4%BC%9A%E8%AD%B0_2026%2F11"
/// let url = URL(string: text)
/// ```
///
/// Text that is all ASCII comes back unchanged, so Foundation's own handling
/// of it is exactly what it was before. The authority (`user@host:port`) is
/// also left as written, so Foundation still converts an internationalized
/// host name to its IDNA form.
public struct URLEscapePreservingEncoder: Sendable {
    /// Creates an encoder.
    public init() {}

    /// Percent-encodes what `text` can't carry, keeping its `%XX` escapes.
    ///
    /// Outside the authority, the result keeps the characters RFC 3986 allows
    /// in a path, query or fragment, plus the first `#`, which starts the
    /// fragment. Every other character becomes its UTF-8 bytes as uppercase
    /// `%XX` escapes. Those are the same characters, in the same form, that
    /// Foundation encodes on its own. A `%` that doesn't start an escape is
    /// encoded as `%25`, just as Foundation does.
    ///
    /// - Parameter text: Absolute URL text (`https://…`, `obsidian://…`,
    ///   `mailto:…`) or a relative reference.
    /// - Returns: The encoded text, or `text` itself when it is all ASCII.
    public func encode(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        let scalars = Array(text.unicodeScalars)
        let authority = authorityRange(in: scalars)
        var encoded = String.UnicodeScalarView()
        var isInFragment = false
        for (index, scalar) in scalars.enumerated() {
            if authority.contains(index) {
                encoded.append(scalar)
                continue
            }
            if keepsAsWritten(scalar, at: index, in: scalars, isInFragment: isInFragment) {
                encoded.append(scalar)
            } else {
                for byte in scalar.utf8 {
                    encoded.append("%")
                    encoded.append(Self.hexDigits[Int(byte >> 4)])
                    encoded.append(Self.hexDigits[Int(byte & 0x0F)])
                }
            }
            if scalar == "#" {
                isInFragment = true
            }
        }
        return String(encoded)
    }

    /// Whether `scalar` can stay unencoded where it sits outside the
    /// authority.
    private func keepsAsWritten(
        _ scalar: Unicode.Scalar,
        at index: Int,
        in scalars: [Unicode.Scalar],
        isInFragment: Bool
    ) -> Bool {
        switch scalar {
        case "%":
            return startsEscape(at: index, in: scalars)
        case "#":
            return !isInFragment
        default:
            return Self.componentCharacters.contains(scalar)
        }
    }

    /// Whether the `%` at `index` is followed by two hexadecimal digits.
    private func startsEscape(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        guard index + 2 < scalars.count else { return false }
        return Self.hexDigitCharacters.contains(scalars[index + 1])
            && Self.hexDigitCharacters.contains(scalars[index + 2])
    }

    /// The scalars between `//` and the next `/`, `?` or `#` when the text has
    /// an authority, after `scheme://` or at the start of a network-path
    /// reference (`//host/path`). Empty otherwise.
    private func authorityRange(in scalars: [Unicode.Scalar]) -> Range<Int> {
        let hierarchyStart = schemeEnd(in: scalars) ?? 0
        guard hierarchyStart + 1 < scalars.count,
              scalars[hierarchyStart] == "/",
              scalars[hierarchyStart + 1] == "/" else {
            return 0..<0
        }
        let start = hierarchyStart + 2
        let end = scalars[start...].firstIndex { scalar in
            scalar == "/" || scalar == "?" || scalar == "#"
        } ?? scalars.count
        return start..<end
    }

    /// The index just past `scheme:` when the text starts with an RFC 3986
    /// scheme: a letter, then letters, digits, `+`, `-` or `.`.
    private func schemeEnd(in scalars: [Unicode.Scalar]) -> Int? {
        guard let first = scalars.first, Self.letterCharacters.contains(first) else { return nil }
        for (index, scalar) in scalars.enumerated().dropFirst() {
            if scalar == ":" {
                return index + 1
            }
            guard Self.schemeCharacters.contains(scalar) else { return nil }
        }
        return nil
    }

    private static let hexDigits = Array("0123456789ABCDEF".unicodeScalars)
    private static let hexDigitCharacters = Set("0123456789ABCDEFabcdef".unicodeScalars)
    private static let letterCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".unicodeScalars
    )
    private static let schemeCharacters = letterCharacters.union("0123456789+-.".unicodeScalars)
    /// RFC 3986 `pchar` plus `/` and `?`: what a path, query or fragment
    /// carries unencoded. `?` only ever appears in a path as the start of the
    /// query, so one set serves all three components.
    private static let componentCharacters = schemeCharacters.union("_~!$&'()*,;=:@/?".unicodeScalars)
}
