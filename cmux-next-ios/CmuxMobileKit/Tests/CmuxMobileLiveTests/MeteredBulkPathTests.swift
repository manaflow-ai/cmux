#if os(iOS)
import CmuxMobileLinkFFI
import Testing
@testable import CmuxMobileTransport

/// NWPathMonitor's bridge keeps Rust's metered gate aligned with the active path.
@Suite(.serialized) struct MeteredBulkPathTests {
    @Test func consentFollowsTheMeteredNetworkUntilWiFiReturns() {
        NetworkPathMonitor.updateMeteredPath(cellular: false, constrained: false)
        #expect(!meteredBulkState().metered)
        #expect(!meteredBulkState().consent)

        // Low Data Mode Wi-Fi is metered and accepts the same consent as cell.
        NetworkPathMonitor.updateMeteredPath(cellular: false, constrained: true)
        #expect(meteredBulkState().metered)
        setMeteredBulkConsent(consent: true)
        #expect(meteredBulkState().consent)

        // Moving to cellular keeps consent for this metered-network span.
        NetworkPathMonitor.updateMeteredPath(cellular: true, constrained: false)
        #expect(meteredBulkState().metered)
        #expect(meteredBulkState().consent)

        // Leaving all metered paths clears the consent in Rust.
        NetworkPathMonitor.updateMeteredPath(cellular: false, constrained: false)
        #expect(!meteredBulkState().metered)
        #expect(!meteredBulkState().consent)
    }
}
#endif
