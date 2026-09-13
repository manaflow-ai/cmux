import Foundation
import Testing

@testable import CmuxCloudBannerCore

@Suite("Cloud banner core")
struct CloudBannerCoreTests {
    @Test("VPN warning preserves unknown and non-off states")
    func vpnWarningOnlyProjectsExplicitOff() {
        #expect(CloudPortsVPNWarning.projection(tunnelState: nil) == nil)
        #expect(CloudPortsVPNWarning.projection(tunnelState: .starting) == nil)
        #expect(CloudPortsVPNWarning.projection(tunnelState: .awaitingApproval) == nil)
        #expect(CloudPortsVPNWarning.projection(tunnelState: .up) == nil)
        #expect(CloudPortsVPNWarning.projection(tunnelState: .stopping) == nil)
        #expect(CloudPortsVPNWarning.projection(tunnelState: .failed("route")) == nil)
        #expect(CloudPortsVPNWarning.projection(tunnelState: .off) != nil)
    }

    @MainActor
    @Test("two live clients preserve each other's dismissals")
    func clientsReadModifyWriteTheCurrentMap() {
        let suiteName = "cloud-banner-core-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CloudBannerDismissalStore(defaults: defaults)
        let second = CloudBannerDismissalStore(defaults: defaults)
        first.dismiss(id: "tunnel", signature: "awaiting-v1")
        second.dismiss(id: "stale", signature: "error-v1")

        #expect(first.isDismissed(id: "tunnel", signature: "awaiting-v1"))
        #expect(first.isDismissed(id: "stale", signature: "error-v1"))
        #expect(second.isDismissed(id: "tunnel", signature: "awaiting-v1"))
        #expect(second.isDismissed(id: "stale", signature: "error-v1"))
    }
}
