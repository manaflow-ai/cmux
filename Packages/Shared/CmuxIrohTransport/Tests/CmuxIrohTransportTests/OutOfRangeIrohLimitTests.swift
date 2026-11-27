import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

/// Limits outside their documented ranges used to trap in a precondition;
/// each now takes a safe value.
@Suite struct OutOfRangeIrohLimitTests {
    @Test func bindingQuotaBelowOneBecomesOne() {
        let quota = CmxIrohActiveBindingConnectionQuota(maximumActiveConnectionsPerBinding: 0)
        #expect(quota.maximumActiveConnectionsPerBinding == 1)
    }

    @Test func laneCountAboveTheCeilingIsLowered() {
        let configuration = CmxIrohProtocolConfiguration(
            alpn: Data("cmux/test/1".utf8),
            maximumHeaderByteCount: 1_024,
            maximumConcurrentClientApplicationLaneCount: CmxIrohProtocolConfiguration.maximumClientApplicationLaneCount + 5
        )
        #expect(configuration.maximumConcurrentClientApplicationLaneCount
            == CmxIrohProtocolConfiguration.maximumClientApplicationLaneCount)
    }
}
