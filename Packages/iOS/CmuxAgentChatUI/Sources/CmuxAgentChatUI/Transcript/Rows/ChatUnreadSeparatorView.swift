import SwiftUI

/// The "Unread messages" separator: an accent-tinted hairline with a
/// centered caption, placed before the first message the user has not seen.
public struct ChatUnreadSeparatorView: View {
    @Environment(\.chatTheme) private var theme

    /// Creates the separator.
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            hairline
            Text(
                String(
                    localized: "chat.unread_separator",
                    defaultValue: "Unread messages",
                    bundle: .module
                )
            )
            .font(.caption)
            .foregroundStyle(theme.accent)
            .fixedSize()
            hairline
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.accent.opacity(0.4))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}
