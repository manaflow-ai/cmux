#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A compact one-time prompt that explains agent push notifications.
struct OnboardingNotificationPrimerView: View {
    let enable: () async -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isEnabling = false
    @State private var shouldBounce = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating, value: shouldBounce)

            Text(L10n.string(
                "mobile.onboarding.push.title",
                defaultValue: "Know the moment an agent needs you"
            ))
            .font(.title2.bold())
            .multilineTextAlignment(.center)

            Text(L10n.string(
                "mobile.onboarding.push.body",
                defaultValue: "cmux sends a push when an agent asks a question or finishes a task."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button {
                guard !isEnabling else { return }
                isEnabling = true
                Task {
                    await enable()
                    dismiss()
                }
            } label: {
                Text(L10n.string(
                    "mobile.onboarding.push.enable",
                    defaultValue: "Enable notifications"
                ))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .contentShape(.capsule)
            }
            .disabled(isEnabling)
            .mobileGlassProminentButton()
            .accessibilityIdentifier("MobileOnboardingPushEnableButton")

            Button(action: dismiss) {
                Text(L10n.string("mobile.onboarding.push.later", defaultValue: "Not now"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .disabled(isEnabling)
            .accessibilityIdentifier("MobileOnboardingPushLaterButton")
        }
        .padding(28)
        .accessibilityIdentifier("MobileOnboardingPushPrimer")
        .onAppear {
            guard !accessibilityReduceMotion else { return }
            shouldBounce = true
        }
    }
}
#endif
