import Foundation

/// Sanitizes untrusted `cmux.json` config text (titles, tooltips, command names, error detail)
/// before it is shown in cmux UI. Strips bidi/zero-width control scalars that could spoof or
/// reorder rendered text, then trims surrounding whitespace and newlines.
public extension String {
    /// This config text with bidi/zero-width control scalars removed and surrounding whitespace
    /// and newlines trimmed.
    ///
    /// Filters the fixed dangerous-scalar set (zero-width spaces/joiners, LTR/RTL marks,
    /// bidi embedding/override/isolate controls, and the byte-order mark) so a malicious config
    /// value cannot reorder or hide the text it renders into.
    var sanitizedCmuxConfigText: String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `sanitizedCmuxConfigText`, or `fallback` when sanitizing leaves an empty string.
    ///
    /// - Parameter fallback: The value to use when the sanitized text is empty.
    func sanitizedCmuxConfigText(fallback: String) -> String {
        let sanitized = sanitizedCmuxConfigText
        return sanitized.isEmpty ? fallback : sanitized
    }
}
