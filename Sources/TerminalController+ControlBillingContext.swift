import CmuxControlSocket
import Foundation

extension TerminalController: ControlBillingContext {
    nonisolated func controlBillingStatus() -> ControlCallResult {
        billingCall {
            await BillingClient.shared.status()
        }
    }

    nonisolated func controlBillingCheckout(plan: String) -> ControlCallResult {
        billingCall {
            await BillingClient.shared.checkout(plan: plan)
        }
    }

    nonisolated func controlBillingPortal() -> ControlCallResult {
        billingCall {
            await BillingClient.shared.portal()
        }
    }

    private nonisolated func billingCall(_ work: @escaping () async -> JSONValue) -> ControlCallResult {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var payload: JSONValue?
        let task = Task {
            payload = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
            return .ok(.object([
                "ok": .bool(false),
                "error": .string("timeout"),
            ]))
        }
        guard let payload else {
            return .ok(.object([
                "ok": .bool(false),
                "error": .string("malformed_response"),
            ]))
        }
        return .ok(payload)
    }
}
