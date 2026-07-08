#if os(iOS)
import SwiftUI

struct MobileSettingsLegalSupportSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section(L10n.string("mobile.settings.legalSupport", defaultValue: "Legal & Support")) {
            externalLinkRow(
                title: L10n.string("mobile.settings.privacyPolicy", defaultValue: "Privacy Policy"),
                systemImage: "hand.raised",
                url: Self.privacyPolicyURL,
                identifier: "MobileSettingsPrivacyPolicy"
            )
            externalLinkRow(
                title: L10n.string("mobile.settings.termsOfService", defaultValue: "Terms of Service"),
                systemImage: "doc.text",
                url: Self.termsOfServiceURL,
                identifier: "MobileSettingsTermsOfService"
            )
            externalLinkRow(
                title: L10n.string("mobile.settings.support", defaultValue: "Support"),
                systemImage: "envelope",
                url: Self.supportURL,
                identifier: "MobileSettingsSupport"
            )
        }
    }

    private static let privacyPolicyURL = URL(string: "https://cmux.com/privacy-policy")!
    private static let termsOfServiceURL = URL(string: "https://cmux.com/terms-of-service")!
    private static let supportURL = URL(string: "mailto:feedback@manaflow.com?subject=cmux%20iOS%20support")!

    private func externalLinkRow(
        title: String,
        systemImage: String,
        url: URL,
        identifier: String
    ) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif
