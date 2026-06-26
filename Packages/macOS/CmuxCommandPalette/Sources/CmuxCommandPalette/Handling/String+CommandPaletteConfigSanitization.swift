import Foundation

extension String {
    /// The receiver with bidirectional-control and zero-width Unicode scalars
    /// stripped and surrounding whitespace trimmed, for safe display of
    /// `cmux.json`-supplied palette titles and subtitles.
    ///
    /// `cmux.json` custom-action titles/subtitles and configuration-issue paths
    /// are user/file-controlled text rendered directly in palette rows. The
    /// removed scalars (RLO/LRO overrides, isolates, zero-width joiners, BOM)
    /// can spoof or reorder visible characters, so they are filtered before
    /// display. The filtered/trimmed result is byte-identical to the legacy
    /// `ContentView.sanitizeCmuxConfigPaletteText(_:)` helper.
    public var cmuxConfigPaletteSanitized: String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
