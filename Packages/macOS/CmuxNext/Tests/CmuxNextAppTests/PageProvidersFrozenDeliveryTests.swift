@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The frozen-delivery policies of PageProviders.swift (p13-webui-024): the daemon relay's change
/// notices resync, never `.latest`, and the policy gate passes the wrapped stream's policy through.
@MainActor
@Suite struct PageProvidersFrozenDeliveryTests {
    @MainActor final class PolicyProvider: PageProvider {
        let policy: PageFrozenDelivery
        init(_ policy: PageFrozenDelivery) { self.policy = policy }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription(frozenDelivery: policy) {}
        }
    }

    @Test func theDaemonRelayResyncsAfterDrops() {
        #expect(DaemonPageRelay.frozenDelivery == .resync)
    }

    @Test(arguments: [PageFrozenDelivery.latest, .resync, .queue(32), .ordered])
    func thePolicyGateForwardsTheWrappedPolicy(_ policy: PageFrozenDelivery) async throws {
        let provider = PolicyGatedPageProvider(inner: PolicyProvider(policy)) { nil }
        let subscription = try await provider.subscribe("cmux.test.changed", filter: .object([:]),
                                                        context: PageCallContext(page: "cmux.test")) { _ in }
        #expect(subscription.frozenDelivery == policy)
        subscription.cancel()
    }
}
