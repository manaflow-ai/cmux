import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A forwarding provider keeps its wrapped stream's ``PageFrozenDelivery``: the
/// confirmation sheet gates calls, never what the router keeps while the page is frozen.
@MainActor
@Suite struct ConfirmingPageProviderFrozenDeliveryTests {
    /// A provider whose every stream declares one policy.
    @MainActor final class PolicyProvider: PageProvider {
        let policy: PageFrozenDelivery
        init(_ policy: PageFrozenDelivery) { self.policy = policy }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription(frozenDelivery: policy) {}
        }
    }

    @MainActor final class NeverAsked: PageConfirmationPresenter {
        func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool { false }
    }

    @Test(arguments: [PageFrozenDelivery.latest, .resync, .queue(32), .ordered])
    func forwardsTheWrappedPolicy(_ policy: PageFrozenDelivery) async throws {
        let provider = ConfirmingPageProvider(inner: PolicyProvider(policy), presenter: NeverAsked()) { _, _ in nil }
        let subscription = try await provider.subscribe("cmux.test.changed", filter: .object([:]),
                                                        context: PageCallContext(page: "cmux.test")) { _ in }
        #expect(subscription.frozenDelivery == policy)
        subscription.cancel()
    }
}
