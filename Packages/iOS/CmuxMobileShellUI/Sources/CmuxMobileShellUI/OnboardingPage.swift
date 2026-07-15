#if os(iOS)
import CmuxMobileSupport
import Foundation

/// Value model for an onboarding page: an SF Symbol, a title, a body, an optional
/// checklist of short bullet items, and zero or more inline links. Pure data so
/// the page list is trivial to extend.
struct OnboardingPage: Sendable {
    let systemImage: String
    let title: String
    let body: String
    /// Short "do this" bullets, shown under the body. Empty when the page is pure
    /// prose. Used by the optional private-network page.
    let checklist: [String]
    /// Inline links shown under the checklist.
    let links: [OnboardingPageLink]

    init(
        systemImage: String,
        title: String,
        body: String,
        checklist: [String] = [],
        links: [OnboardingPageLink] = []
    ) {
        self.systemImage = systemImage
        self.title = title
        self.body = body
        self.checklist = checklist
        self.links = links
    }

    /// The ordered first-run pages: what cmux is, how Iroh connects, optional
    /// private-network paths, and how to pair.
    static var allPages: [OnboardingPage] {
        [whatItIs, howItConnects, privateNetworkOptions, pairNow]
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
            )
        )
    }

    private static var howItConnects: OnboardingPage {
        OnboardingPage(
            systemImage: "lock.laptopcomputer",
            title: L10n.string(
                "mobile.onboarding.connectTitle",
                defaultValue: "Encrypted wherever you connect"
            ),
            body: L10n.string(
                "mobile.onboarding.connectBody",
                defaultValue: "cmux uses Iroh by default. It connects directly to your Mac when possible and uses a cmux relay when needed. Your Mac's identity and cmux account are verified end to end, so the relay cannot read terminal traffic."
            )
        )
    }

    private static var privateNetworkOptions: OnboardingPage {
        OnboardingPage(
            systemImage: "point.3.connected.trianglepath.dotted",
            title: L10n.string(
                "mobile.onboarding.privateNetworkTitle",
                defaultValue: "Private networks stay available"
            ),
            body: L10n.string(
                "mobile.onboarding.privateNetworkBody",
                defaultValue: "After cmux admits both devices over Iroh, Tailscale, WireGuard, another VPN, or the same LAN may become a faster direct path. They are optional, and Iroh keeps its encryption and identity checks."
            ),
            checklist: [
                L10n.string(
                    "mobile.onboarding.privateNetworkStep1",
                    defaultValue: "Sign this phone and the Mac in to the same cmux account."
                ),
                L10n.string(
                    "mobile.onboarding.privateNetworkStep2",
                    defaultValue: "Leave cmux running on the Mac so Iroh can reconnect."
                ),
                L10n.string(
                    "mobile.onboarding.privateNetworkStep3",
                    defaultValue: "Optional: connect both devices to the same private network so an admitted Iroh session can migrate to it."
                ),
            ],
            links: [
                OnboardingPageLink(
                    title: L10n.string(
                        "mobile.onboarding.tailscaleAppStoreLink",
                        defaultValue: "Optional: Tailscale for iPhone"
                    ),
                    url: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
                ),
                OnboardingPageLink(
                    title: L10n.string(
                        "mobile.onboarding.tailscaleLink",
                        defaultValue: "Optional: Tailscale for Mac"
                    ),
                    url: URL(string: "https://tailscale.com/download")!
                ),
            ]
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
                defaultValue: "Open Pair iPhone in cmux on your Mac and scan its Iroh code. cmux saves the verified Mac identity and reconnects automatically. Tailscale, another VPN, or the same LAN may speed up the authenticated Iroh connection."
            )
        )
    }
}
#endif
