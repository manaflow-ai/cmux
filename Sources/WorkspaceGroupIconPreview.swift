import SwiftUI

struct WorkspaceGroupIconPreview: View, Equatable {
    let icon: RenderableWorkspaceGroupIcon
    /// Glyph point size. The sidebar group header passes its metric-derived `iconFontSize` so the icon
    /// scales with the configured sidebar font size; other call sites (picker rows) use the default.
    var fontSize: CGFloat = 13

    var body: some View {
        switch icon {
        case .systemSymbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
        case .emoji(let emoji):
            // Emoji glyphs read slightly small next to SF Symbols at the same point size; nudge up,
            // preserving the original 13->14 relationship while still scaling with `fontSize`.
            Text(emoji)
                .font(.system(size: fontSize + 1))
        }
    }
}
