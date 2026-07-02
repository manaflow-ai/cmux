import Testing
@testable import CmuxMobileWorkspace

/// The pairing scanner accepts any cmux channel's pairing scheme (`cmux-ios://`
/// for release, `cmux-ios-dev://` for development). This guards the predicate
/// the UI hands to the camera service so a generic QR code (a URL, a Wi-Fi join
/// code) can never be mistaken for a pairing link, while cross-channel pairing
/// from inside the app still works.
@Suite struct MobilePairingScannerPolicyTests {
    @Test(arguments: [
        ("cmux-ios://attach?ticket=abc", true),
        ("cmux-ios://", true),
        ("cmux-ios-dev://attach?v=3&tr=ticket-ref-123&r=100.64.0.5:58465", true),
        ("cmux-ios-dev://", true),
        ("https://example.com", false),
        ("WIFI:S:net;;", false),
        ("", false),
    ])
    func acceptsOnlyPairingLinks(code: String, expected: Bool) {
        #expect(MobilePairingScannerPolicy.acceptsCode(code) == expected)
    }
}
