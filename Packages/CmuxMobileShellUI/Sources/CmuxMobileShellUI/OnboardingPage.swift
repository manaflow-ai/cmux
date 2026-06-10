#if os(iOS)
import CmuxMobileSupport
import Foundation

/// Value model for an onboarding page: an SF Symbol, a title, a body, and an
/// optional inline link (used by the Tailscale page to point at the install
/// page). Pure data so the page list is trivial to extend (e.g. a future Hive
/// "add your own servers" page).
struct OnboardingPage: Sendable {
    let systemImage: String
    let title: String
    let body: String
    let link: OnboardingPageLink?

    /// The ordered first-run pages: what cmux is, how it connects (Tailscale),
    /// and how to pair.
    static var allPages: [OnboardingPage] {
        [whatItIs, howItConnects, pairNow]
    }

    private static var whatItIs: OnboardingPage {
        OnboardingPage(
            systemImage: "terminal",
            title: L10n.string(
                "mobile.onboarding.whatTitle",
                defaultValue: "Your Mac's terminals, on your phone"
            ),
            body: L10n.string(
                "mobile.onboarding.whatBody",
                defaultValue: "cmux runs your terminals and AI coding agents on your Mac. This app lets you watch them, type, and get notified when an agent needs you, right from your phone."
            ),
            link: nil
        )
    }

    private static var howItConnects: OnboardingPage {
        OnboardingPage(
            systemImage: "lock.laptopcomputer",
            title: L10n.string(
                "mobile.onboarding.connectTitle",
                defaultValue: "A private link to your Mac"
            ),
            body: L10n.string(
                "mobile.onboarding.connectBody",
                defaultValue: "Your phone connects straight to your Mac over Tailscale, with both signed in to the same cmux account. It is a direct, private connection to a computer you own, not a cloud relay. Put your Mac and phone on the same tailnet to pair."
            ),
            link: OnboardingPageLink(
                title: L10n.string(
                    "mobile.onboarding.tailscaleLink",
                    defaultValue: "Set up Tailscale"
                ),
                // Tailscale download/install page. Pairing also works over a
                // trusted LAN host, but Tailscale is the recommended private path
                // (see PairingView's manual-host trust warning).
                url: URL(string: "https://tailscale.com/download")!
            )
        )
    }

    private static var pairNow: OnboardingPage {
        OnboardingPage(
            systemImage: "qrcode.viewfinder",
            title: L10n.string(
                "mobile.onboarding.pairTitle",
                defaultValue: "Pair your Mac"
            ),
            body: L10n.string(
                "mobile.onboarding.pairBody",
                defaultValue: "Make sure cmux on your Mac is signed in to the same account, then scan the pairing QR code it shows (or enter its address by hand). You only do this once per Mac."
            ),
            link: nil
        )
    }
}
#endif
