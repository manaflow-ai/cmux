import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxHive

struct HivePairingInputTests {
    @Test func acceptsExplicitNumericDestination() {
        #expect(HivePairingInput(" 100.64.0.2:9876 \n") == .manual(.init(host: "100.64.0.2", port: 9876)))
        #expect(HivePairingInput("[fd7a:115c:a1e0::2]:9876") == .manual(.init(host: "fd7a:115c:a1e0::2", port: 9876)))
    }

    @Test(arguments: ["", "100.64.0.2", "100.64.0.2:0", "100.64.0.2:65536", "https://example.com:443", "user@100.64.0.2:9876", "100.64.0.2:9876/path", "100.64.0.2:9876?route=other", "100.64.0.2:9876#fragment"])
    func rejectsAmbiguousDestinations(input: String) {
        #expect(HivePairingInput(input) == nil)
    }

    @Test(arguments: [1, 65535])
    func acceptsInclusivePortBoundary(port: Int) {
        #expect(HivePairingInput("100.64.0.2:\(port)") == .manual(.init(host: "100.64.0.2", port: port)))
    }

    @Test func acceptsRecognizedPairingLinkWithoutExecutingIt() {
        let link = "cmux-ios://pair?v=2"
        #expect(HivePairingInput(link) == .link(link))
        #expect(HivePairingInput("unrelated://pair?v=2") == nil)
    }
}
