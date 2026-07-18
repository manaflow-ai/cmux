#if DEBUG
import SwiftUI

/// Labels a current-scheme Signal palette token with its exact specification value.
struct SignalPaletteSwatch: View {
    let name: String
    let hex: String
    let color: Color
    let markSize: CGFloat
    let theme: SignalTheme

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(color)
                .frame(width: markSize, height: markSize)
                .overlay {
                    Rectangle()
                        .stroke(theme.hairline, lineWidth: 1)
                }
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .tracking(0.88)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(hex)
                    .font(.system(.footnote, design: .monospaced, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
#endif
