#if DEBUG
import SwiftUI

/// Presents one notification-style activity fixture with status and unread redundancy.
struct MeridianActivityRow: View {
    let entry: GalleryActivityEntry

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MeridianStatusSymbol(state: entry.state, font: .headline)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text)
                    .font(entry.unread ? .body.weight(.semibold) : .body)
                    .foregroundStyle(theme.label)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(theme.label(for: entry.state))
                        .foregroundStyle(theme.color(for: entry.state))
                    Text("·")
                    Text(entry.timeText)
                }
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
            }

            if entry.unread {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 7)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 58)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
