#if os(iOS)
import CmuxMobileSupport
import CmuxMobileWorkspace
import Foundation

/// The static guidance shown for one setup gate in ``SetupHelpView``.
struct SetupHelpGateContent {
    let systemImage: String
    let title: String
    let body: String
    let link: SetupHelpGateLink?
    let identifierSuffix: String
    let linkAccessibilityIdentifier: String

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
                    defaultValue: "Sign in to cmux on this phone with the same account the paired computer uses. Without that, there is nothing to connect to."
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
                    defaultValue: "Install cmux on your computer and leave it running, signed in to the same account. The phone pairs to a running cmux build, so a quit or never-installed app is the most common reason pairing does nothing."
                ),
                link: nil,
                identifierSuffix: "signedInNeverPaired",
                linkAccessibilityIdentifier: "MobileSetupHelpMacAppLink"
            )
        case .macUnreachable:
            return SetupHelpGateContent(
                systemImage: "wifi.exclamationmark",
                title: L10n.string("mobile.setupHelp.unreachableTitle", defaultValue: "Wake the computer"),
                body: L10n.string(
                    "mobile.setupHelp.unreachableBody",
                    defaultValue: "You have paired this computer before but it is not reachable now. Wake it, make sure cmux is running, and confirm both devices are on the same tailnet or Wi-Fi. Then reconnect."
                ),
                link: nil,
                identifierSuffix: "macUnreachable",
                linkAccessibilityIdentifier: "MobileSetupHelpUnreachableLink"
            )
        case .accountMismatch:
            return SetupHelpGateContent(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: L10n.string("mobile.setupHelp.mismatchTitle", defaultValue: "Match the account"),
                body: L10n.string(
                    "mobile.setupHelp.mismatchBody",
                    defaultValue: "If the computer rejects this device's sign-in, the two are on different cmux accounts or this device's session is stale. Sign this phone in to the computer's account (or sign the computer in to this one), then pair again."
                ),
                link: nil,
                identifierSuffix: "accountMismatch",
                linkAccessibilityIdentifier: "MobileSetupHelpMismatchLink"
            )
        }
    }
}
#endif
