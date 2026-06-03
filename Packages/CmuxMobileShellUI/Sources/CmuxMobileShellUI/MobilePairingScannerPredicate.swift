import Foundation

/// Whether a scanned QR payload is a cmux pairing link.
///
/// cmux pairing QR codes carry a `cmux-ios://` deep link; any other QR content
/// (a website URL, a Wi-Fi join code) must be ignored so the scanner never hands
/// the connection layer a non-pairing string.
func mobilePairingScannerAcceptsCode(_ code: String) -> Bool {
    code.hasPrefix("cmux-ios://")
}
