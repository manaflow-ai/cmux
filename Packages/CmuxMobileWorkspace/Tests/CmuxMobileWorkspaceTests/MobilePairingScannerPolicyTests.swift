import Testing
@testable import CmuxMobileWorkspace

/// The pairing scanner only accepts `cmux-ios://` QR payloads. This guards the
/// predicate the UI hands to the camera service so a generic QR code (a URL, a
/// Wi-Fi join code) can never be mistaken for a pairing link.
@Suite struct MobilePairingScannerPolicyTests {
    @Test(arguments: [
        ("cmux-ios://attach?ticket=abc", true),
        ("cmux-ios://", true),
        ("https://example.com", false),
        ("WIFI:S:net;;", false),
        ("", false),
    ])
    func acceptsOnlyPairingLinks(code: String, expected: Bool) {
        #expect(MobilePairingScannerPolicy.acceptsCode(code) == expected)
    }
}
