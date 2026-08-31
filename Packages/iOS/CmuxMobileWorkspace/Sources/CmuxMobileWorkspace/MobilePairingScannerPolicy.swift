internal import CMUXMobileCore
import Foundation

/// Pure policy deciding whether a scanned QR payload is a cmux pairing link.
///
/// cmux pairing QR codes carry a bundle-specific pairing deep link (see
/// ``CmxPairingURLScheme``); any other QR content (a website URL, a Wi-Fi join
/// code) must be ignored so the scanner never hands the connection layer a
/// non-pairing string. The in-app scanner accepts every official release scheme
/// so one canonical Mac QR can pair App Store, BETA, INTERNAL, and DEMO builds.
public struct MobilePairingScannerPolicy {
    private init() {}

    /// Whether `code` is a cmux pairing deep link the scanner should accept.
    /// - Parameter code: The raw string payload decoded from a QR code.
    /// - Returns: `true` for any cmux channel's pairing deep link.
    public static func acceptsCode(_ code: String) -> Bool {
        if CmxPairingURLScheme(urlString: code) != nil {
            return true
        }
        // Keep future bundle-specific attach schemes flowing to the decoder so
        // it can show the update-your-iPhone-app guidance. A scanner that drops
        // them here would leave the user with no failure surface at all.
        guard let components = URLComponents(string: code),
              (components.host == "attach" || components.host == "pair"),
              let scheme = components.scheme?.lowercased() else {
            return false
        }
        return scheme.hasPrefix("cmux-ios-")
    }
}
