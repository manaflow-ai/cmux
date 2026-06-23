#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Pure visibility rule for the workspaces-list notification prompt, kept
/// separate from the view so it is unit-testable (mirrors `MobileOnboardingGate`).
enum NotificationBannerPolicy {
    /// Show the banner only when notifications are off AND the user has not
    /// permanently dismissed it. Enabling notifications or tapping "Ignore
    /// forever" both make this `false`.
    static func shouldShow(isEnabled: Bool, dismissedForever: Bool) -> Bool {
        !isEnabled && !dismissedForever
    }
}

/// A compact, dismissible prompt shown at the top of the workspaces list when
/// notifications are off, nudging the user to enable agent notifications. Pure
/// value/closure inputs (no store/coordinator reference) so it is safe to mount
/// as a list header.
struct NotificationPromptBanner: View {
    /// Fire the OS permission prompt (or open Settings if previously denied).
    let onEnable: () -> Void
    /// Permanently dismiss the banner.
    let onIgnoreForever: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.notifications.bannerTitle",
                        defaultValue: "Turn on notifications"
                    ))
                    .font(.subheadline.weight(.semibold))
                    Text(L10n.string(
                        "mobile.notifications.bannerBody",
                        defaultValue: "Get notified when an agent finishes or needs you, even when your phone is locked."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack {
                Button {
                    onIgnoreForever()
                } label: {
                    Text(L10n.string(
                        "mobile.notifications.bannerIgnoreForever",
                        defaultValue: "Ignore forever"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("MobileNotificationBannerIgnoreButton")

                Spacer()

                Button {
                    onEnable()
                } label: {
                    Text(L10n.string(
                        "mobile.notifications.bannerEnable",
                        defaultValue: "Enable"
                    ))
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("MobileNotificationBannerEnableButton")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityIdentifier("MobileNotificationBanner")
    }
}
#endif
