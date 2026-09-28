/// Styled text art parsed from a file of terminal output, such as `figlet`,
/// `toilet`, `chafa` or `lolcat` output.
///
/// Produced by ``ANSIArtParser``; render it with
/// ``attributedString(palette:)`` in a monospaced font.
public struct ANSIArt: Hashable, Sendable {
    /// The art's lines, top to bottom. Never empty.
    public var lines: [ANSIArtLine]

    /// Creates art from parsed lines.
    ///
    /// - Parameter lines: The lines, top to bottom.
    public init(lines: [ANSIArtLine]) {
        self.lines = lines
    }

    /// The width of the widest line, in character cells.
    public var columnCount: Int {
        lines.map(\.columnCount).max() ?? 0
    }
}
