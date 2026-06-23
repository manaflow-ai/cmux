#if os(iOS)
import CmuxMobileSupport
import Foundation

/// Value model for an onboarding page: an SF Symbol, a title, a body, an optional
/// checklist of short bullet items, and zero or more inline links. Pure data so
/// the page list is trivial to extend (e.g. a future Hive "add your own servers"
/// page).
struct OnboardingPage: Sendable {
    let systemImage: String
    let title: String
    let body: String
    /// Short "do this" bullets, shown under the body. Empty when the page is pure
    /// prose. Used by the Tailscale checklist page.
    let checklist: [String]
    /// Inline links shown under the checklist (e.g. the Tailscale App Store link
    /// for the phone and the Tailscale download page for the Mac).
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

    /// The ordered first-run pages: what cmux is, how it connects (the private
    /// link), the Tailscale set-up checklist (both devices), and how to pair.
    static var allPages: [OnboardingPage] {
        [whatItIs, howItConnects, tailscaleChecklist, pairNow]
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
                defaultValue: "A private link to your Mac"
            ),
            // Honest about the path: the phone reaches the Mac directly. QR
            // pairing uses Tailscale auto-discovery, while manual host/port
            // pairing can use any user-managed VPN or trusted LAN route.
            body: L10n.string(
                "mobile.onboarding.connectBody",
                defaultValue: "Your phone has to reach your Mac over the network. Tailscale is the easiest private path and enables QR pairing. If you already use another VPN or a trusted LAN, type the Mac's host or IP address and port by hand."
            )
        )
    }

    private static var tailscaleChecklist: OnboardingPage {
        OnboardingPage(
            systemImage: "point.3.connected.trianglepath.dotted",
            title: L10n.string(
                "mobile.onboarding.tailscaleTitle",
                defaultValue: "Use a private network"
            ),
            body: L10n.string(
                "mobile.onboarding.tailscaleBody",
                defaultValue: "Tailscale is a free option, but cmux also works over your own VPN or trusted LAN when you enter the Mac's host and port manually."
            ),
            checklist: [
                L10n.string(
                    "mobile.onboarding.tailscaleStep1",
                    defaultValue: "Put this phone and your Mac on Tailscale, your VPN, or the same trusted LAN."
                ),
                L10n.string(
                    "mobile.onboarding.tailscaleStep2",
                    defaultValue: "Confirm the phone can reach the Mac's hostname or IP address."
                ),
                L10n.string(
                    "mobile.onboarding.tailscaleStep3",
                    defaultValue: "Keep both signed in to the same cmux account too. Pairing checks that they match."
                ),
            ],
            links: [
                OnboardingPageLink(
                    title: L10n.string(
                        "mobile.onboarding.tailscaleAppStoreLink",
                        defaultValue: "Get Tailscale for iPhone"
                    ),
                    url: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
                ),
                OnboardingPageLink(
                    title: L10n.string(
                        "mobile.onboarding.tailscaleLink",
                        defaultValue: "Set up Tailscale on the Mac"
                    ),
                    // Tailscale download/install page (links every platform).
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
                defaultValue: "Make sure cmux on your Mac is signed in to the same account, then scan the pairing QR code it shows (or enter its address by hand). You only do this once per Mac."
            )
        )
    }
}
#endif
