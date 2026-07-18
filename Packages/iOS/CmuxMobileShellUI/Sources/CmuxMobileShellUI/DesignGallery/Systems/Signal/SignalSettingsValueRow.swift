#if DEBUG
import SwiftUI

/// Displays one Settings label and right-aligned monospaced fixture value.
struct SignalSettingsValueRow: View {
    let label: String
    let value: String
    let theme: SignalTheme

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(.subheadline, design: .default, weight: .regular))
                .foregroundStyle(theme.ink)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(.footnote, design: .monospaced, weight: .regular))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.74)
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
