#if os(iOS)
import CmuxMobileSupport

enum MobilePairingCopy {
    static var enableOnMac: String {
        L10n.string(
            "mobile.pairing.enableOnMac",
            defaultValue: "Before pairing, open cmux Settings > Mobile on the Mac and turn on Enable iOS pairing. This Mac stays hidden from iOS while it is off."
        )
    }
}
#endif
