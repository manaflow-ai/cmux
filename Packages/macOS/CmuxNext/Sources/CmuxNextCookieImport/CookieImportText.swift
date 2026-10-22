import Foundation

/// Makes an agent's own words safe to show on the permission card: the agent writes the reason and
/// the site list, so neither may restyle the card. Control characters and the bidirectional
/// overrides and isolates (which can make "moc.knab" read "bank.com") are removed, runs of white
/// space collapse to one space, and the text is cut to a length the card shows whole. Sites show
/// in their ASCII (punycode) form, so a look-alike domain in another script cannot pass for a
/// familiar one.
struct CookieImportText {
    /// The longest reason shown, in characters; a longer one ends with "…".
    static let reasonLimit = 400
    /// The most sites listed by name; the rest are counted ("and 12 more").
    static let siteLimit = 12

    /// Scalars that change how text after them is laid out or read: U+200E/F marks, U+202A-E embeddings
    /// and overrides, U+2066-9 isolates, and the zero-width joiners and spaces, plus the BOM.
    private static let layoutScalars: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D,
                                                     0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]

    /// `text` with no control or layout characters, its white space collapsed, at most `limit` characters.
    func shown(_ text: String, limit: Int = CookieImportText.reasonLimit) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if Self.layoutScalars.contains(scalar.value) { continue }
            let isSpace = scalar.properties.isWhitespace || CharacterSet.controlCharacters.contains(scalar)
            if isSpace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
        }
        var result = String(out)
        while result.hasSuffix(" ") { result.removeLast() }
        guard result.count > limit else { return result }
        return String(result.prefix(limit - 1)) + "…"
    }

    /// A site as the card names it: lowercased, its leading dot dropped, in ASCII (an IDN in its
    /// `xn--` form); nil when it is not a host name at all.
    func site(_ raw: String) -> String? {
        var host = shown(raw, limit: 253).lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        if !host.unicodeScalars.allSatisfy(\.isASCII) {
            // URLComponents encodes a non-ASCII host with IDNA (punycode).
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            guard let encoded = components.url?.host(percentEncoded: true), encoded.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
            host = encoded
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }
}
