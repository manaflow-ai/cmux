#if os(iOS)
import Foundation
import CmuxMobileSupport
import CmuxMobileWorkspace

/// The static guidance shown for one setup gate in ``SetupHelpView``.
struct SetupHelpGateContent {
    let systemImage: String
    let title: String
    let body: String
    let link: SetupHelpGateLink?
    let identifierSuffix: String
    let linkAccessibilityIdentifier: String

    /// Stable public contract for the iOS connection guide. The companion
    /// guide screenshots can evolve without changing the app's deep link.
    static let macOSSetupGuideURL = URL(string: "https://cmux.com/docs/ios")!

    /// Maps a setup gate to its title, icon, copy, and optional link. Pure and
    /// scoped to the content type so the gate guidance is data, separate from
    /// the view that lays it out.
    static func content(for gate: MobileSetupGuidanceState) -> SetupHelpGateContent {
        switch gate {
        case .notSignedIn:
            return SetupHelpGateContent(
                systemImage: "person.crop.circle",
                title: L10n.string("mobile.setupHelp.signInTitle", defaultValue: "Sign in"),
                body: L10n.string(
                    "mobile.setupHelp.signInBody",
                    defaultValue: "Sign in to cmux on this phone with the same account your computer uses. Once you sign in, your computer is found automatically."
                ),
                link: nil,
                identifierSuffix: "notSignedIn",
                linkAccessibilityIdentifier: "MobileSetupHelpSignInLink"
            )
        case .signedInNeverPaired:
            return SetupHelpGateContent(
                systemImage: "desktopcomputer",
                title: L10n.string("mobile.setupHelp.macAppTitle", defaultValue: "Run cmux on your computer"),
                body: L10n.string(
                    "mobile.setupHelp.macAppBody",
                    defaultValue: """
                    Install cmux on your computer, sign in to the same account, and leave it running. \
                    The computer then appears on this phone automatically. \
                    To pair through Tailscale, install Tailscale on both devices \
                    and connect them to the same Tailscale network. \
                    Open Mobile Pairing on the Mac and scan its QR here, or enter the Mac's \
                    numeric Tailscale IP and port.
                    """
                ) + " " + MobilePairingCopy().enableOnMac,
                link: SetupHelpGateLink(
                    title: L10n.string(
                        "mobile.setupHelp.macAppGuideLink",
                        defaultValue: "Mac setup guide"
                    ),
                    url: macOSSetupGuideURL
                ),
                identifierSuffix: "signedInNeverPaired",
                linkAccessibilityIdentifier: "MobileSetupHelpMacAppLink"
            )
        case .macUnreachable:
            return SetupHelpGateContent(
                systemImage: "wifi.exclamationmark",
                title: L10n.string("mobile.setupHelp.unreachableTitle", defaultValue: "Wake the computer"),
                body: L10n.string(
                    "mobile.setupHelp.unreachableBody",
                    defaultValue: "You paired this computer before, but it is not reachable now. Wake it and make sure cmux is running; this phone reconnects on its own."
                ),
                link: SetupHelpGateLink(
                    title: L10n.string(
                        "mobile.setupHelp.macAppGuideLink",
                        defaultValue: "Mac setup guide"
                    ),
                    url: macOSSetupGuideURL
                ),
                identifierSuffix: "macUnreachable",
                linkAccessibilityIdentifier: "MobileSetupHelpUnreachableLink"
            )
        case .accountMismatch:
            return SetupHelpGateContent(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: L10n.string("mobile.setupHelp.mismatchTitle", defaultValue: "Match the account"),
                body: L10n.string(
                    "mobile.setupHelp.mismatchBody",
                    defaultValue: "The computer rejected this phone's sign-in, so the two are on different cmux accounts or this phone's session is stale. Sign either one out and back in so both use the same account, then try again."
                ),
                link: nil,
                identifierSuffix: "accountMismatch",
                linkAccessibilityIdentifier: "MobileSetupHelpMismatchLink"
            )
        }
    }
}
#endif
