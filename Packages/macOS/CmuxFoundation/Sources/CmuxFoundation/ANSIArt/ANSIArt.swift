/// Styled text art parsed from a file of terminal output, such as `figlet`,
/// `toilet`, `chafa` or `lolcat` output.
///
/// Produced by ``ANSIArtParser``. Draw it on a monospaced cell grid, resolving
/// colors with ``ANSIArtPalette`` and filling block characters with
/// ``ANSIArtBlockElement``.
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

    /// The number of character cells `scalar` advances, as a terminal lays it
    /// out: 0 for combining marks and format characters, which join the
    /// previous cell; 2 for East Asian wide characters and emoji; else 1.
    ///
    /// - Parameter scalar: A printable scalar from the art.
    /// - Returns: 0, 1 or 2.
    public static func cellWidth(of scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
