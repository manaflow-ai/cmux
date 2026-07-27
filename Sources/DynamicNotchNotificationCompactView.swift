import SwiftUI

/// Collapsed bell and pending-count display for the Dynamic Notch tray.
struct DynamicNotchNotificationCompactView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)

            Text(count, format: .number)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "notifications.title", defaultValue: "Notifications")
        )
        .accessibilityValue(Text(count, format: .number))
        .accessibilityIdentifier("DynamicNotchNotificationCompact")
    }
}
