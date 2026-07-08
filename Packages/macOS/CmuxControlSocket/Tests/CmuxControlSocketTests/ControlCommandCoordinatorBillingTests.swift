import Testing
@testable import CmuxControlSocket

private final class FakeBillingControlCommandContext: ControlCommandContext {
    nonisolated(unsafe) var checkoutPlan: String?

    nonisolated func controlBillingStatus() -> ControlCallResult {
        .ok(.object([
            "source": .string("https://cmux.com"),
            "plan": .object(["planId": .string("free")]),
        ]))
    }

    nonisolated func controlBillingCheckout(plan: String) -> ControlCallResult {
        checkoutPlan = plan
        return .ok(.object(["ok": .bool(true), "url": .string("https://checkout.stripe.com/c/test")]))
    }

    nonisolated func controlBillingPortal() -> ControlCallResult {
        .ok(.object(["ok": .bool(true), "url": .string("https://billing.stripe.com/p/session")]))
    }
}

@Suite("ControlCommandCoordinator billing domain")
struct ControlCommandCoordinatorBillingTests {
    @Test @MainActor func statusDispatchesToBillingContext() {
        let context = FakeBillingControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handleSocketWorkerV2(
            ControlRequest(id: nil, method: "billing.status", params: [:]),
            context: context
        )

        #expect(result == .ok(.object([
            "source": .string("https://cmux.com"),
            "plan": .object(["planId": .string("free")]),
        ])))
    }

    @Test @MainActor func checkoutDefaultsToPro() {
        let context = FakeBillingControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handleSocketWorkerV2(
            ControlRequest(id: nil, method: "billing.checkout", params: [:]),
            context: context
        )

        #expect(context.checkoutPlan == "pro")
    }

    @Test @MainActor func checkoutRejectsUnknownPlanAsStructuredBillingState() {
        let context = FakeBillingControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handleSocketWorkerV2(
            ControlRequest(
                id: nil,
                method: "billing.checkout",
                params: ["plan": .string("enterprise")]
            ),
            context: context
        )

        #expect(result == .ok(.object([
            "ok": .bool(false),
            "error": .string("invalid_plan"),
            "billing": .string("invalid_plan"),
        ])))
    }
}
