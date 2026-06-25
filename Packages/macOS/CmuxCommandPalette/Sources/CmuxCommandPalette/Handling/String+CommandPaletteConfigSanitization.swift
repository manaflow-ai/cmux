import Foundation

internal import CmuxFoundation

extension String {
    /// The receiver with bidirectional-control and zero-width Unicode scalars
    /// stripped and surrounding whitespace trimmed, for safe display of
    /// `cmux.json`-supplied palette titles and subtitles.
    ///
    /// `cmux.json` custom-action titles/subtitles and configuration-issue paths
    /// are user/file-controlled text rendered directly in palette rows. The
    /// removed scalars (RLO/LRO overrides, isolates, zero-width joiners, BOM)
    /// can spoof or reorder visible characters, so they are filtered before
    /// display. Forwards to `CmuxFoundation`'s canonical
    /// `sanitizedCmuxConfigText` so the dangerous-scalar set lives in exactly
    /// one place; this remains byte-identical to the legacy
    /// `ContentView.sanitizeCmuxConfigPaletteText(_:)` helper.
    public var cmuxConfigPaletteSanitized: String {
        sanitizedCmuxConfigText
    }
}
