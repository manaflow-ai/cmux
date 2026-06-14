import CMUXMobileCore
import CmuxMobileTerminalKit
import Testing

@Suite struct MobileTerminalScrollForwardingPolicyTests {
    @Test func primaryScreenScrollStaysLocal() {
        let policy = MobileTerminalScrollForwardingPolicy()

        #expect(policy.shouldForwardToHost(activeScreen: .primary) == false)
    }

    @Test func alternateScreenScrollForwardsToHost() {
        let policy = MobileTerminalScrollForwardingPolicy()

        #expect(policy.shouldForwardToHost(activeScreen: .alternate))
    }
}
