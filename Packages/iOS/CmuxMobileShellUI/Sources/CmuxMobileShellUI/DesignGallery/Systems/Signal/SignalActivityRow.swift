#if DEBUG
import SwiftUI

/// Aligns an activity time, status square, and event text into a fixed table row.
struct SignalActivityRow: View {
    let entry: GalleryActivityEntry
    let theme: SignalTheme

    private var status: SignalStatusStyle {
        SignalStatusStyle(state: entry.state, theme: theme)
    }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 10) {
                Text(entry.timeText)
                    .font(.system(.footnote, design: .monospaced, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 48, alignment: .leading)

                SignalStatusSquare(color: status.color)

                Text(entry.text)
                    .font(.system(
                        .subheadline,
                        design: .default,
                        weight: entry.unread ? .semibold : .regular
                    ))
                    .foregroundStyle(entry.unread ? theme.ink : theme.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(status.symbol)
                    .font(.system(.footnote, design: .monospaced, weight: .semibold))
                    .foregroundStyle(entry.unread ? theme.ink : theme.secondaryText)
                    .frame(width: 16)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(theme.surface)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 1)
            }
        }
        .buttonStyle(SignalRowButtonStyle())
        .accessibilityLabel("\(entry.timeText), \(status.label), \(entry.text)")
    }
}
#endif
