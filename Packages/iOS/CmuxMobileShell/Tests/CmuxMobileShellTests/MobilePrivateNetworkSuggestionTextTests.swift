import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@Suite
struct MobilePrivateNetworkSuggestionTextTests {
    @Test func appendsAndCanonicalizesSuggestionDeduplication() throws {
        let suggestion = try #require(CmxPrivateNetworkAddress.classify(
            interfaceName: "utun4",
            address: "fd00::8"
        ))
        let text = MobilePrivateNetworkSuggestionText()

        #expect(text.appending(
            suggestion,
            to: "10.0.0.1"
        ) == "10.0.0.1\nfd00::8")
        #expect(text.appending(
            suggestion,
            to: "fd00:0:0:0:0:0:0:8"
        ) == "fd00:0:0:0:0:0:0:8")
        #expect(text.contains(
            suggestion,
            in: "10.0.0.1\nfd00:0:0:0:0:0:0:8"
        ))
    }
}
