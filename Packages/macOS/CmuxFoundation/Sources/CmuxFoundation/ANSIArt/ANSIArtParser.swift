public import Foundation

/// Parses a file of terminal art into styled lines.
///
/// Honors SGR (`ESC [ … m`) colors and weights: reset, bold, dim, inverse, the
/// 16 base colors, 256-color (`38;5;n`) and truecolor (`38;2;r;g;b`, also the
/// colon forms). Cursor forward (`ESC [ n C`) and repeat (`ESC [ n b`), which
/// `chafa` uses to compress output, place blank or repeated cells. Every other
/// escape sequence (other cursor movement, erase, OSC titles and hyperlinks,
/// DCS, charset selection) and every control character except newline and tab
/// is dropped, so art captured from a terminal renders as its visible text
/// only. Malformed sequences never leak their bytes into the text.
///
/// Text is measured in grapheme clusters, so an emoji sequence takes one
/// two-cell character, and at most 16
/// scalars are kept in one cell.
///
/// Input is capped: data over ``maxBytes`` is rejected, and lines past
/// ``maxLines`` or cells past ``maxColumns`` are cut off.
///
/// ```swift
/// let art = ANSIArtParser().parse(data: try Data(contentsOf: url))
/// ```
public struct ANSIArtParser: Sendable {
    /// The default byte cap: 64 KB, well above a large `chafa` render.
    public static let defaultMaxBytes = 64 * 1024
    /// The default line cap.
    public static let defaultMaxLines = 200
    /// The default column cap.
    public static let defaultMaxColumns = 400
    /// Tab stops are every 8 cells, as in a terminal.
    public static let tabWidth = 8

    /// Inputs larger than this many UTF-8 bytes are rejected.
    public let maxBytes: Int
    /// Lines past this count are dropped.
    public let maxLines: Int
    /// Cells past this column on a line are dropped.
    public let maxColumns: Int

    /// Creates a parser with the given caps.
    ///
    /// - Parameters:
    ///   - maxBytes: The largest accepted input, in bytes.
    ///   - maxLines: The most lines kept.
    ///   - maxColumns: The most cells kept per line.
    public init(
        maxBytes: Int = Self.defaultMaxBytes,
        maxLines: Int = Self.defaultMaxLines,
        maxColumns: Int = Self.defaultMaxColumns
    ) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
        self.maxColumns = maxColumns
    }

    /// Parses file contents, decoding UTF-8 leniently.
    ///
    /// - Parameter data: The raw file contents.
    /// - Returns: The art, or `nil` when the data is over ``maxBytes`` or has
    ///   no visible content.
    public func parse(data: Data) -> ANSIArt? {
        guard data.count <= maxBytes else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses text containing ANSI escape sequences.
    ///
    /// - Parameter text: The art text.
    /// - Returns: The art, or `nil` when the text is over ``maxBytes`` or has
    ///   no visible content.
    public func parse(_ text: String) -> ANSIArt? {
        guard text.utf8.count <= maxBytes else { return nil }
        var scanner = ANSIArtScanner(
            scalars: Array(text.unicodeScalars),
            builder: ANSIArtBuilder(maxLines: maxLines, maxColumns: maxColumns, tabWidth: Self.tabWidth)
        )
        scanner.scan()
        return scanner.builder.finish()
    }
}
