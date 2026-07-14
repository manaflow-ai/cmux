#if DEBUG
import SwiftUI

/// Presents one opaque Phosphor settings row with an optional mono value.
struct PhosphorSettingsRow: View {
    let symbol: String
    let title: String
    let value: String?
    let showsChevron: Bool

    @Environment(\.colorScheme) private var colorScheme
    private let typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        Button(action: {}) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 24)

                Text(title)
                    .font(typography.body)
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 8)

                if let value {
                    Text(value)
                        .font(typography.data)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PhosphorPressButtonStyle())
        .background(theme.bg1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
                .padding(.leading, 48)
        }
    }
}
#endif
