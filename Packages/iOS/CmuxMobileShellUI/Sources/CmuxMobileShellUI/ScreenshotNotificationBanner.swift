#if canImport(UIKit) && DEBUG
import SwiftUI

/// A non-interactive iOS-style notification banner drawn for App Store
/// screenshots, to show off cmux's agent push notifications. Overlaid on the
/// workspace-list preview when `CMUX_UITEST_NOTIFICATION_BANNER=1`.
struct ScreenshotNotificationBanner: View {
    var title: String
    var message: String
    var appName: String = "CMUX"
    var timeText: String = "now"

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.30, green: 0.36, blue: 0.98),
                                 Color(red: 0.55, green: 0.30, blue: 0.95)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.9))
                        .tracking(0.3)
                    Spacer()
                    Text(timeText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        )
        .padding(.horizontal, 10)
    }
}

#Preview {
    ZStack {
        Color(.systemBackground)
        ScreenshotNotificationBanner(
            title: "Agent needs your input",
            message: "Claude is asking: which database should I use, Postgres or SQLite?"
        )
    }
}
#endif
