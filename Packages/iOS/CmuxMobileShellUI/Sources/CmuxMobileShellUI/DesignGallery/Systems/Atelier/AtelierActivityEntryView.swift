#if DEBUG
import SwiftUI

/// Renders one activity event as a journal sentence with redundant state signaling.
struct AtelierActivityEntryView: View {
    let entry: GalleryActivityEntry

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)
        let color = theme.color(for: entry.state)

        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: 22, height: 22)
                Image(systemName: theme.symbol(for: entry.state))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text)
                    .font(.system(size: 16, weight: entry.unread ? .medium : .regular))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(theme.label(for: entry.state)) · \(entry.timeText)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
            }

            Spacer(minLength: 8)

            if entry.unread {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
                    .padding(.top, 8)
                    .accessibilityLabel("Unread")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
