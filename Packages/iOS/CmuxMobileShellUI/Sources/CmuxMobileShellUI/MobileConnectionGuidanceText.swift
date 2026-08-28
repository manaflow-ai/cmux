#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport

/// Connection-guidance copy shared by the Computers screen and the
/// disconnected shell. Every Mac-version claim interpolates
/// ``MobileMacPairingFloor/requiredMacVersionLabel`` so the surfaces can never
/// disagree about the minimum Mac version and the release-cut edit stays one
/// value.
enum MobileConnectionGuidanceText {
    /// Empty-state guidance when no computer has ever been discovered.
    static var noComputersDiscoveryGuidance: String {
        String(
            format: L10n.string(
                "mobile.connections.emptyFormat",
                defaultValue: """
                No computers yet. Iroh finds Macs running %@. Both devices must be signed in \
                to the same cmux account, and the Mac must keep cmux running while both \
                devices are online. If any requirement is missing, the Mac will not appear \
                automatically. To use Tailscale instead, open Settings, tap Connection \
                Method, and choose Tailscale Only.
                """
            ),
            MobileMacPairingFloor.requiredMacVersionLabel
        )
    }

    /// Discovery requirements shown when a saved Mac is not reachable.
    static var discoveryRequirementsGuidance: String {
        String(
            format: L10n.string(
                "mobile.devices.emptyDescriptionFormat",
                defaultValue: """
                For Iroh to find a Mac, run %@ on the Mac, sign in to cmux on both devices \
                with the same account, and keep cmux running on the Mac while both devices \
                are online. If any requirement is missing, the Mac will not appear \
                automatically. To use Tailscale instead, open Settings, tap Connection \
                Method, and choose Tailscale Only.
                """
            ),
            MobileMacPairingFloor.requiredMacVersionLabel
        )
    }
}
#endif
