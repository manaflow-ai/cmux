import Foundation
import Testing

@testable import CmuxCloudBannerCore

@Suite("Cloud banner core")
struct CloudBannerCoreTests {
    @MainActor
    @Test("separate clients preserve persisted dismissals")
    func clientsReadModifyWriteTheCurrentMap() {
        let suiteName = "cloud-banner-core-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CloudBannerDismissalStore(defaults: defaults)
        let second = CloudBannerDismissalStore(defaults: defaults)
        first.dismiss(id: "tunnel", signature: "awaiting-v1")
        second.dismiss(id: "stale", signature: "error-v1")

        let restored = CloudBannerDismissalStore(defaults: defaults)
        #expect(restored.isDismissed(id: "tunnel", signature: "awaiting-v1"))
        #expect(restored.isDismissed(id: "stale", signature: "error-v1"))
    }
}
