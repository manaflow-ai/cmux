import AppKit
import Foundation

/// Foreground colors for each token kind, tuned for dark and light editor
/// backgrounds. The base (uncolored) text keeps the editor's own foreground.
/// Built and consumed entirely on the main thread, so it does not need to be
/// `Sendable` (which `NSColor` is not).
struct FilePreviewSyntaxTheme {
    let keyword: NSColor
    let type: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let function: NSColor
    let attribute: NSColor

    func color(for kind: FilePreviewSyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .function: return function
        case .attribute: return attribute
        }
    }

    /// Decides whether to use the dark palette by inspecting the editor's
    /// foreground color: light text means a dark background, and vice versa.
    /// Sidesteps the `usesClearContentBackground` case where the content
    /// background color is `.clear` and carries no usable luminance.
    static func prefersDarkPalette(foreground: NSColor) -> Bool {
        guard let rgb = foreground.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance >= 0.5
    }

    static func theme(prefersDark: Bool) -> FilePreviewSyntaxTheme {
        prefersDark ? .dark : .light
    }

    static let dark = FilePreviewSyntaxTheme(
        keyword: NSColor(srgbRed: 0.98, green: 0.47, blue: 0.66, alpha: 1.0),
        type: NSColor(srgbRed: 0.40, green: 0.85, blue: 0.94, alpha: 1.0),
        string: NSColor(srgbRed: 0.60, green: 0.84, blue: 0.55, alpha: 1.0),
        number: NSColor(srgbRed: 0.95, green: 0.71, blue: 0.49, alpha: 1.0),
        comment: NSColor(srgbRed: 0.50, green: 0.56, blue: 0.62, alpha: 1.0),
        function: NSColor(srgbRed: 0.55, green: 0.76, blue: 0.99, alpha: 1.0),
        attribute: NSColor(srgbRed: 0.85, green: 0.69, blue: 0.99, alpha: 1.0)
    )

    static let light = FilePreviewSyntaxTheme(
        keyword: NSColor(srgbRed: 0.66, green: 0.13, blue: 0.44, alpha: 1.0),
        type: NSColor(srgbRed: 0.13, green: 0.42, blue: 0.55, alpha: 1.0),
        string: NSColor(srgbRed: 0.13, green: 0.50, blue: 0.20, alpha: 1.0),
        number: NSColor(srgbRed: 0.62, green: 0.36, blue: 0.05, alpha: 1.0),
        comment: NSColor(srgbRed: 0.40, green: 0.46, blue: 0.52, alpha: 1.0),
        function: NSColor(srgbRed: 0.15, green: 0.36, blue: 0.78, alpha: 1.0),
        attribute: NSColor(srgbRed: 0.45, green: 0.27, blue: 0.66, alpha: 1.0)
    )
}
