#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The tour's notification opt-in stage.
///
/// Presented immediately after the demo where an agent asked for input, so
/// the permission has just-demonstrated context per the HIG: the request is
/// integrated into onboarding with its benefit shown, and declining is a
/// first-class path (the footer offers Not Now). The preview card is
/// cmux-styled on purpose — never a mock of the system alert.
struct WelcomeNotificationsStageView: View {
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(L10n.string(
                    "mobile.welcome.notifications.title",
                    defaultValue: "Know the moment an agent needs you"
                ))
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                Text(L10n.string(
                    "mobile.welcome.notifications.subtitle",
                    defaultValue: "Questions like the one you just answered arrive as notifications. Reply right from the Lock Screen, and the agent keeps going."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            notificationPreviewCard
        }
        .accessibilityIdentifier("MobileWelcomeStage-notifications")
    }

    /// A cmux-styled preview of an agent question, not a system-alert mock.
    private var notificationPreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "app.badge.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: "cmux")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(L10n.string("mobile.welcome.notifications.now", defaultValue: "now"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.string(
                "mobile.welcome.notifications.cardTitle",
                defaultValue: "Agent needs input · fix the flaky auth test"
            ))
            .font(.subheadline.weight(.semibold))
            Text(L10n.string(
                "mobile.welcome.notifications.cardBody",
                defaultValue: "Replace the mock clock with a fake timer?"
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                previewChip(L10n.string(
                    "mobile.welcome.notifications.cardReply",
                    defaultValue: "Yes, replace it"
                ))
                previewChip(L10n.string(
                    "mobile.welcome.notifications.cardOpen",
                    defaultValue: "Open workspace"
                ))
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PlatformPalette.separator.opacity(0.5))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string(
            "mobile.welcome.notifications.cardAccessibility",
            defaultValue: "Example notification: an agent asks a question and offers reply actions."
        ))
    }

    private func previewChip(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.fill.secondary, in: Capsule())
            .foregroundStyle(.primary)
    }
}
#endif
