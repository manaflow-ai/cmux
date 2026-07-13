#if DEBUG
import SwiftUI

/// Teaches one Signal state through its square, word, symbol, and plain-language meaning.
struct SignalStatusMeaningRow: View {
    let style: SignalStatusStyle
    let theme: SignalTheme

    var body: some View {
        HStack(spacing: 10) {
            SignalStatusSquare(color: style.color)

            Text(style.label)
                .font(.system(.caption2, design: .default, weight: .semibold))
                .tracking(0.88)
                .foregroundStyle(theme.ink)
                .frame(width: 74, alignment: .leading)

            Text(style.symbol)
                .font(.system(.footnote, design: .monospaced, weight: .bold))
                .foregroundStyle(theme.ink)
                .frame(width: 16)

            Text(style.meaning)
                .font(.system(.subheadline, design: .default, weight: .regular))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }
}
#endif
