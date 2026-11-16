/// `appearance.fontSmoothing` in cmux.json: how heavy cmux's own (native) text draws.
///
/// macOS "font smoothing" is stem darkening: glyph strokes drawn a little bolder than their
/// outlines, more so for light text on a dark background. Web apps that set
/// `-webkit-font-smoothing: antialiased` (cmux's own web UI included) turn it off.
public nonisolated enum FontSmoothing: String, Sendable, CaseIterable, Codable {
    /// Thin strokes with no stem darkening, as `-webkit-font-smoothing: antialiased` draws, so
    /// native text matches the web UI beside it. The default.
    case antialiased
    /// The Mac's own setting (`AppleFontSmoothing` in the global domain): stem darkening on unless
    /// the person turned it off for every app.
    case system
}
