#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit

/// A non-interactive iOS-style notification banner drawn for App Store
/// screenshots, to show off cmux's agent push notifications. Overlaid on the
/// workspace-list preview when `CMUX_UITEST_NOTIFICATION_BANNER=1`. Uses the
/// real cmux app icon (embedded) so it reads as a genuine push.
struct ScreenshotNotificationBanner: View {
    var title: String
    var message: String
    var appName: String = "CMUX"
    var timeText: String = "now"

    private static let iconImage: UIImage? =
        Data(base64Encoded: iconB64).flatMap(UIImage.init(data:))

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let img = Self.iconImage {
                    Image(uiImage: img).resizable()
                } else {
                    Color(red: 0.36, green: 0.30, blue: 0.96)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(appName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                    Spacer(minLength: 4)
                    Text(timeText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 9)
        )
        .padding(.horizontal, 11)
    }
}

private let iconB64 = "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"
#endif
