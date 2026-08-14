#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Sets context for the system notification prompt with a faithful preview of
/// the alert users receive when an agent needs their attention.
struct OnboardingNotificationsView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingNotificationsScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.notifications.body",
                    defaultValue: "Get a push when work finishes or needs your input. Tap to open the right workspace."
                ),
                visual: OnboardingPushPreview()
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.notifications.title",
            defaultValue: "Know when your agent needs you"
        )
    }
}

private struct OnboardingPushPreview: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(previewBackground)

            Image("CmuxLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                .frame(width: 270, height: 270)
                .offset(x: 88, y: 44)

            VStack(spacing: 0) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("9:41")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                Spacer(minLength: 24)

                OnboardingPushBanner()
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingPushPreview")
    }

    private var previewBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(uiColor: .systemGray5)
    }
}

private struct OnboardingPushBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                OnboardingPushAppIcon()

                Text(L10n.string(
                    "mobile.onboarding.pushPreview.appName",
                    defaultValue: "cmux"
                ))
                .font(.caption.weight(.semibold))

                Spacer(minLength: 8)

                Text(L10n.string(
                    "mobile.onboarding.pushPreview.time",
                    defaultValue: "now"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(L10n.string(
                "mobile.onboarding.pushPreview.title",
                defaultValue: "Codex needs your input"
            ))
            .font(.subheadline.weight(.semibold))

            Text(L10n.string(
                "mobile.onboarding.pushPreview.body",
                defaultValue: "Approve the command to keep work moving."
            ))
            .font(.subheadline)
            .foregroundStyle(.primary.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .modifier(OnboardingPushBannerMaterial())
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileOnboardingPushBanner")
    }
}

private struct OnboardingPushAppIcon: View {
    var body: some View {
        Image("CmuxLogo")
            .resizable()
            .scaledToFit()
            .padding(5)
            .frame(width: 32, height: 32)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private struct OnboardingPushBannerMaterial: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                )
        }
    }
}
#endif
