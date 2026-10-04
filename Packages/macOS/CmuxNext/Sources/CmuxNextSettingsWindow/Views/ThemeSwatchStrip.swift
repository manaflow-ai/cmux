import CmuxNextDesign
import SwiftUI

/// A theme's colors side by side in a small rounded bar (R98): the theme
/// rows of the Settings theme picker. No colors (the Ghostty config row, a
/// typed spec, a strip not loaded yet) keeps the same width, empty, so the
/// names stay aligned. Decorative: the row's name is its label.
struct ThemeSwatchStrip: View {
    let colors: [ThemeRGB]

    static let size = CGSize(width: 44, height: 14)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.itemCornerRadius / 2, style: .continuous)
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(Color(nsColor: color.nsColor))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay { if !colors.isEmpty { shape.strokeBorder(SettingsStyle.separator, lineWidth: 1) } }
        .accessibilityHidden(true)
    }
}
