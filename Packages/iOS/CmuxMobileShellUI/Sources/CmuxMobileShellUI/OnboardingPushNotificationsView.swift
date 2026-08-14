#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Sets context for the system notification prompt with a notification banner
/// captured from iOS instead of approximating Apple's private visual effects.
struct OnboardingPushNotificationsView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingPushNotificationsScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.pushNotifications.body",
                    defaultValue: "Get a push when work finishes or needs your input. Tap to open the right workspace."
                ),
                visual: OnboardingSystemNotificationPreview()
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.pushNotifications.title",
            defaultValue: "Know when your agent needs you"
        )
    }
}

private struct OnboardingSystemNotificationPreview: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // 1,105 pixels is the native width of the @3x system capture.
                    // Capping at its point width prevents iOS typography from scaling up.
                    .frame(maxWidth: 368.33)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.onboarding.pushPreview.accessibilityLabel",
            defaultValue: "cmux notification: Agent needs your input."
        ))
        .accessibilityIdentifier("MobileOnboardingPushPreview")
    }

    private var resourceName: String {
        let language = OnboardingScreenshotLanguage.resolve(locale: locale)
        return "Onboarding-push-\(language.rawValue)"
    }

    private var image: UIImage? {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
#endif
