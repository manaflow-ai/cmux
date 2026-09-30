import Foundation
import Testing

@testable import CmuxCloudBannerCore

@Suite("Cloud banner core")
struct CloudBannerCoreTests {
    @MainActor
    @Test("isDismissed observes changes made by the store")
    func dismissalQueryInvalidatesObservation() async {
        let suiteName = "cloud-banner-observation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CloudBannerDismissalStore(defaults: defaults)
        let changes = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = store.isDismissed(id: "tree", signature: "error-v1")
        } onChange: {
            changes.continuation.yield()
        }

        store.dismiss(id: "tree", signature: "error-v1")

        var iterator = changes.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(store.isDismissed(id: "tree", signature: "error-v1"))
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
