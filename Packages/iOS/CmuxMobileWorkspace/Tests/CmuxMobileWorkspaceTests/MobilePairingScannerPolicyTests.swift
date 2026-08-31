import Testing
@testable import CmuxMobileWorkspace

/// The pairing scanner accepts every official release variant plus development
/// and legacy schemes. This guards the predicate the UI hands to the camera
/// service so a generic QR code (a URL, a Wi-Fi join code) can never be
/// mistaken for a pairing link, while one Mac QR works in every official app.
@Suite struct MobilePairingScannerPolicyTests {
    @Test(arguments: [
        ("cmux-ios://attach?ticket=abc", true),
        ("cmux-ios://", true),
        ("cmux-ios-com.cmux.app://attach?v=2&r=100.64.0.5:58465", true),
        ("cmux-ios-dev.cmux.app.beta://attach?v=2&r=100.64.0.5:58465", true),
        ("cmux-ios-dev.cmux.app.internal://attach?v=2&r=100.64.0.5:58465", true),
        ("cmux-ios-dev.cmux.app.demo://attach?v=2&r=100.64.0.5:58465", true),
        ("cmux-ios-dev://attach?v=2&r=100.64.0.5:58465", true),
        ("cmux-ios-dev://", true),
        ("cmux-ios-dev.cmux.app.future://attach?v=2&r=100.64.0.5:58465", true),
        ("https://example.com", false),
        ("WIFI:S:net;;", false),
        ("", false),
    ])
    func acceptsOnlyPairingLinks(code: String, expected: Bool) {
        #expect(MobilePairingScannerPolicy.acceptsCode(code) == expected)
    }
}
