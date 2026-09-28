import AppKit
import CmuxFoundation
import SwiftUI

/// A few lines of shell and code set in the terminal font, size, and line
/// height being chosen, with the glyphs people compare fonts by (0O, 1lI,
/// operators, brackets).
struct TerminalFontPreview: View {
    let family: String?
    let size: Double
    let cellHeight: GhosttyCellHeightAdjustment

    @Environment(\.displayScale) private var displayScale

    private struct Token {
        let text: String
        let style: Style
    }

    private enum Style {
        case plain, prompt, keyword, string, comment
    }

    private static let lines: [[Token]] = [
        [Token(text: "~/src/app ", style: .comment), Token(text: "❯ ", style: .prompt), Token(text: "cargo run --release", style: .plain)],
        [Token(text: "fn ", style: .keyword), Token(text: "render(glyphs: &[Glyph]) -> Result<()> {", style: .plain)],
        [Token(text: "    // 0O 1lI |! => != >= <= -> {}[]()", style: .comment)],
        [Token(text: "    let ", style: .keyword), Token(text: "title = ", style: .plain), Token(text: "\"Hello, cmux\"", style: .string), Token(text: ";", style: .plain)],
        [Token(text: "}", style: .plain)],
    ]

    var body: some View {
        let font = NSFont.terminalPreview(family: family, size: CGFloat(size))
        VStack(alignment: .leading, spacing: lineSpacing(for: font)) {
            ForEach(Self.lines.indices, id: \.self) { index in
                Self.lines[index].reduce(Text(verbatim: "")) { line, token in
                    line + Text(verbatim: token.text).foregroundColor(color(token.style))
                }
                .lineLimit(1)
            }
        }
        .font(Font(font))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "settings.terminal.font.preview.accessibility",
            defaultValue: "Terminal font preview"
        ))
        .accessibilityIdentifier("SettingsTerminalFontPreview")
    }

    /// Extra space between lines matching Ghostty's `adjust-cell-height`: a
    /// percentage of the font's line height, or a number of device pixels.
    private func lineSpacing(for font: NSFont) -> CGFloat {
        let lineHeight = font.ascender - font.descender + font.leading
        switch cellHeight {
        case .percent(let percent): return lineHeight * CGFloat(percent) / 100
        case .pixels(let pixels): return CGFloat(pixels) / max(displayScale, 1)
        }
    }

    private func color(_ style: Style) -> Color {
        switch style {
        case .plain: return .primary
        case .prompt: return .green
        case .keyword: return .purple
        case .string: return .orange
        case .comment: return .secondary
        }
    }
}
