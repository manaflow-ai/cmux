import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor
struct DockBadgeObservationTests {
    @Test func theStreamOwnsItsObservedObjectUntilCancellation() async throws {
        weak var observed: PolicySource?
        let policies = autoreleasepool {
            let source = PolicySource()
            observed = source
            return DockBadge.activationPolicies(of: source, keyPath: \.activationPolicy)
        }
        // NSKeyValueObservation alone does not keep its observed object alive.
        #expect(observed != nil)
        try #require(observed != nil)
        observed?.activationPolicy = .accessory
        var iterator = policies.makeAsyncIterator()
        #expect(await iterator.next() == .accessory)

        let consumer = Task {
            for await _ in policies {}
        }
        consumer.cancel()
        await consumer.value
        #expect(observed == nil, "cancellation must invalidate KVO and release the observed object")
    }
}

private final class PolicySource: NSObject {
    @objc dynamic var activationPolicy: NSApplication.ActivationPolicy = .regular
}
