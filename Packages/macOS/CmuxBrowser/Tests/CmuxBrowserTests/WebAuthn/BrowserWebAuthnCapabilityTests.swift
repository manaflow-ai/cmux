import Testing
@testable import CmuxBrowser

@Suite
struct BrowserWebAuthnCapabilityTests {
    @Test
    @MainActor
    func nativeCapabilityReplyOmitsUnavailablePlatformSignals() throws {
        let reply = BrowserWebAuthnCoordinator().capabilityReply()
        let capabilities = try #require(reply["capabilities"] as? [String: Bool])

        #expect(reply["ok"] as? Bool == true)
        #expect(capabilities.isEmpty)
    }
}
