#if DEBUG
import SwiftUI

/// Shows one fixed status mark with its fleet count and compact label.
struct SignalLegendItem: View {
    let style: SignalStatusStyle
    let count: Int
    let theme: SignalTheme

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                SignalStatusSquare(color: style.color)
                Text("\(count)")
                    .font(.system(.footnote, design: .monospaced, weight: .semibold))
                    .foregroundStyle(theme.ink)
            }

            SignalSectionLabel(text: style.compactLabel, color: theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.label), \(count)")
    }
}
#endif
