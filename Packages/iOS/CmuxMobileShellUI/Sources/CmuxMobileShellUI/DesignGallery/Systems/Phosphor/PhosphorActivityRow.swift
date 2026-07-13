#if DEBUG
import SwiftUI

/// Displays one compact activity event with redundant status information.
struct PhosphorActivityRow: View {
    let entry: GalleryActivityEntry

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)
        let statusColor = theme.statusColor(entry.state)

        HStack(spacing: 8) {
            PhosphorStatusDot(state: entry.state)

            Image(systemName: theme.statusSymbol(entry.state))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 12)

            Text(entry.text)
                .font(theme.isNeedsYou(entry.state) ? typography.bodySemibold : typography.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 6)

            if entry.unread {
                Circle()
                    .fill(statusColor)
                    .frame(width: 4, height: 4)
                    .accessibilityHidden(true)
            }

            Text(entry.timeText)
                .font(typography.monoCaption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(theme.bg1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
                .padding(.leading, 40)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(theme.statusLabel(entry.state)), \(entry.text), \(entry.timeText)\(entry.unread ? ", unread" : "")"
        )
    }
}
#endif
