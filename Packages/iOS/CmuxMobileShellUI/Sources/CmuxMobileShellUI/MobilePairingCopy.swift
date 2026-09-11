#if os(iOS)
import CmuxMobileSupport

enum MobilePairingCopy {
    static var enableOnMacShort: String {
        L10n.string(
            "mobile.pairing.enableOnMac.short",
            defaultValue: "Enable iOS pairing in cmux Settings > Mobile on your Mac."
        )
    }

    static var enableOnMac: String {
        L10n.string(
            "mobile.pairing.enableOnMac",
            defaultValue: "Before pairing, open cmux Settings > Mobile on the Mac and turn on Enable iOS pairing. This Mac stays hidden from iOS while it is off."
        )
    }

    static var emptyWorkspaceMessage: String {
        L10n.string(
            "mobile.workspaces.empty.message",
            defaultValue: "Enable iOS pairing in cmux Settings > Mobile on your Mac, sign in to the same cmux account on both devices, and keep cmux running. Your Mac and its workspaces will appear here after pairing is enabled."
        )
    }
}
#endif
