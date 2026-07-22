#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingWorkspacePreviewRow: View {
    let color: Color
    let systemImage: String
    let title: String
    let subtitle: String
    let showsUnread: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color.gradient)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsUnread {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            showsUnread
                ? L10n.string("mobile.notificationFeed.unread", defaultValue: "Unread")
                : ""
        )
    }
}
#endif
