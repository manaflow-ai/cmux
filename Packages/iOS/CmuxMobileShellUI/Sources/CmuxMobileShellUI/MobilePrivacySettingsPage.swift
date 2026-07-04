#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobilePrivacySettingsPage: View {
    var body: some View {
        Form {
            Section {
                Text(L10n.string("mobile.settings.privacy.voice", defaultValue: "Parakeet transcription always runs on this iPhone. The Apple engine prefers on-device recognition; when your language does not support it, Apple's servers may process the audio."))
                Text(L10n.string("mobile.settings.privacy.terminal", defaultValue: "Terminal data flows only between your devices through your cmux account connection."))
                Text(L10n.string("mobile.settings.privacy.notifications", defaultValue: "Push notifications may include agent or terminal activity summaries."))
                Link(destination: URL(string: "https://cmux.com/privacy-policy")!) {
                    Label(
                        L10n.string("mobile.settings.privacyPolicy", defaultValue: "Privacy Policy"),
                        systemImage: "hand.raised"
                    )
                }
                .accessibilityIdentifier("MobileSettingsPrivacyPolicy")
            }
        }
        .navigationTitle(L10n.string("mobile.settings.privacy", defaultValue: "Privacy"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileSettingsPrivacyPage")
    }
}
#endif
