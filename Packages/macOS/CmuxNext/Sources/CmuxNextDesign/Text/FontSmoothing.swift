/// `appearance.fontSmoothing` in cmux.json: how cmux's text draws, in the CSS model
/// (`-webkit-font-smoothing`), for native and web text alike.
///
/// macOS "font smoothing" is stem darkening: glyph strokes drawn a little bolder than their
/// outlines, more so for light text on a dark background (measured on cmux-lawrence-2 at 13 pt:
/// 15% more ink for dark text on light, 26% for light text on dark at 2x). Native and web text in
/// the same mode draw the same pixels. On a Mac with the default settings ``auto`` and ``subpixel``
/// look the same; they differ only where the person turned smoothing off for every app.
public nonisolated enum FontSmoothing: String, Sendable, CaseIterable, Codable {
    /// No override, the look cmux had before this setting: native text follows the Mac's own
    /// smoothing (the `AppleFontSmoothing` global default) and each web page keeps its own CSS (the
    /// chat's text is `antialiased`). The default.
    case auto
    /// Thin grayscale strokes with no stem darkening, native and web
    /// (`-webkit-font-smoothing: antialiased` on every element).
    case antialiased
    /// macOS font smoothing on, native and web (`-webkit-font-smoothing: subpixel-antialiased`),
    /// even where the Mac turned it off for every app (web pages then still draw thin: WebKit
    /// follows the Mac's choice).
    case subpixel

    /// The CSS value pages draw with; nil for ``auto`` (each page keeps its own).
    public var cssValue: String? {
        switch self {
        case .auto: nil
        case .antialiased: "antialiased"
        case .subpixel: "subpixel-antialiased"
        }
    }
}
