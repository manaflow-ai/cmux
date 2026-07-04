#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileAboutSettingsPage: View {
    var body: some View {
        Form {
            Section(L10n.string("mobile.settings.about", defaultValue: "About")) {
                LabeledContent {
                    Text(AppVersionInfo.current().displayString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label(
                        L10n.string("mobile.settings.version", defaultValue: "Version"),
                        systemImage: "info.circle"
                    )
                }
                .accessibilityIdentifier("MobileSettingsVersionRow")

                settingsLink(
                    title: L10n.string("mobile.settings.privacyPolicy", defaultValue: "Privacy Policy"),
                    systemImage: "hand.raised",
                    url: URL(string: "https://cmux.com/privacy-policy")!,
                    identifier: "MobileSettingsAboutPrivacyPolicy"
                )
                settingsLink(
                    title: L10n.string("mobile.settings.termsOfService", defaultValue: "Terms of Service"),
                    systemImage: "doc.text",
                    url: URL(string: "https://cmux.com/terms-of-service")!,
                    identifier: "MobileSettingsAboutTerms"
                )
                settingsLink(
                    title: L10n.string("mobile.settings.support", defaultValue: "Support"),
                    systemImage: "questionmark.circle",
                    url: URL(string: "https://cmux.com/support")!,
                    identifier: "MobileSettingsAboutSupport"
                )
            }

            Section(L10n.string("mobile.settings.acknowledgements", defaultValue: "Acknowledgements")) {
                Text(L10n.string("mobile.settings.acknowledgement.fluidAudio", defaultValue: "FluidAudio — Apache-2.0"))
                Text(L10n.string("mobile.settings.acknowledgement.parakeet", defaultValue: "NVIDIA Parakeet TDT 0.6B v3 — CC-BY-4.0"))
            }
        }
        .navigationTitle(L10n.string("mobile.settings.about", defaultValue: "About"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileSettingsAboutPage")
    }

    private func settingsLink(title: String, systemImage: String, url: URL, identifier: String) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif
