import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor
struct DockBadgeObservationTests {
    @Test func theStreamOwnsItsObservedObjectUntilCancellation() async throws {
        weak var observed: PolicySource?
        var source: PolicySource?
        let policies: AsyncStream<NSApplication.ActivationPolicy> = {
            let created = PolicySource()
            source = created
            observed = created
            return DockBadge.activationPolicies(of: created, keyPath: \.activationPolicy)
        }()
        // NSKeyValueObservation alone does not keep its observed object alive.
        source = nil
        #expect(observed != nil)
        try #require(observed != nil)
        let receiver = Task {
            var iterator = policies.makeAsyncIterator()
            return await iterator.next()
        }
        observed?.activationPolicy = .accessory
        #expect(await receiver.value == .accessory)
        let consumer = Task {
            for await _ in policies {}
        }
        consumer.cancel()
        await consumer.value
        #expect(observed == nil, "stream cancellation must invalidate KVO and release the observed object")
    }
}

private final class PolicySource: NSObject {
    @objc dynamic var activationPolicy: NSApplication.ActivationPolicy = .regular
}
