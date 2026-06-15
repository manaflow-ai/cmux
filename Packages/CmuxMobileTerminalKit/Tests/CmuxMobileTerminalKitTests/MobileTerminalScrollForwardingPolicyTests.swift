import CMUXMobileCore
import CmuxMobileTerminalKit
import Testing

@Suite struct MobileTerminalScrollForwardingPolicyTests {
    @Test func primaryScreenScrollStaysLocal() {
        let policy = MobileTerminalScrollForwardingPolicy()

        #expect(policy.shouldApplyLocally(activeScreen: .primary, decouplePrimaryScreenScroll: true))
        #expect(policy.shouldForwardToHost(activeScreen: .primary, decouplePrimaryScreenScroll: true) == false)
    }

    @Test func primaryScreenScrollCanUseHostRoundTripForComparison() {
        let policy = MobileTerminalScrollForwardingPolicy()

        #expect(policy.shouldApplyLocally(activeScreen: .primary, decouplePrimaryScreenScroll: false) == false)
        #expect(policy.shouldForwardToHost(activeScreen: .primary, decouplePrimaryScreenScroll: false))
    }

    @Test func alternateScreenScrollForwardsToHost() {
        let policy = MobileTerminalScrollForwardingPolicy()

        #expect(policy.shouldApplyLocally(activeScreen: .alternate, decouplePrimaryScreenScroll: true) == false)
        #expect(policy.shouldForwardToHost(activeScreen: .alternate, decouplePrimaryScreenScroll: true))
    }
}
