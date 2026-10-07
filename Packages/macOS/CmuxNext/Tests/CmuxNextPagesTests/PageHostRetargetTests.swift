import CmuxNextSettings
import Foundation
@testable import CmuxNextPages
import Testing

/// Retargeting a pooled page must end the previous page's router ownership before binding the next.
@MainActor
@Suite struct PageHostRetargetTests {
    final class Provider: PageProvider {
        var callArrived: (() -> Void)?
        var pending: CheckedContinuation<JSONValue, any Error>?
        var cancelled = 0

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            callArrived?()
            callArrived = nil
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription { [weak self] in self?.cancelled += 1 }
        }

        func waitForCall() async {
            guard pending == nil else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                callArrived = { continuation.resume() }
            }
        }
    }

    @Test func retargetCancelsCallsAndSubscriptionsBeforeTheNewPageBinds() async {
        let provider = Provider()
        let router = PageRouter(descriptor: .settings,
                                routes: [PageRoute(prefix: "cmux.settings.", provider: provider)])
        let call = Task { await router.handle(["t": .string("call"), "id": .number(1),
                                                "op": .string("cmux.settings.slow"), "params": .object([:])]) }
        await provider.waitForCall()
        _ = await router.handle(["t": .string("sub"), "id": .number(2),
                                 "stream": .string("cmux.settings.changed"), "filter": .object([:])])

        router.rebind(descriptor: .history, routes: [])
        let reply = await call.value
        #expect(reply["code"]?.stringValue == PageError.opCancelled.code)
        #expect(router.subscriptionCount == 0)
        #expect(provider.cancelled == 1)
    }
}
