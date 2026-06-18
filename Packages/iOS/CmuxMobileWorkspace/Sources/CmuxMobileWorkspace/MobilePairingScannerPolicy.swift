internal import CMUXMobileCore
import Foundation

/// Pure policy deciding whether a scanned QR payload is a cmux pairing link.
///
/// cmux pairing QR codes carry a channel-specific pairing deep link
/// (`cmux-ios://` for release builds, `cmux-ios-dev://` for development; see
/// ``CmxPairingURLScheme``); any other QR content (a website URL, a Wi-Fi join
/// code) must be ignored so the scanner never hands the connection layer a
/// non-pairing string. The in-app scanner accepts every channel's scheme so a
/// user can pair across channels from inside the app.
public struct MobilePairingScannerPolicy {
    private init() {}

    /// Whether `code` is a cmux pairing deep link the scanner should accept.
    /// - Parameter code: The raw string payload decoded from a QR code.
    /// - Returns: `true` for any cmux channel's pairing deep link.
    public static func acceptsCode(_ code: String) -> Bool {
        CmxPairingURLScheme.hasPairingScheme(code)
    }
}
