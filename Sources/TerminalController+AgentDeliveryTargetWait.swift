import Foundation

/// Process-wide publication signal for the topology read by
/// `agent.resolve_delivery_target`. Every mutation is protected by `condition`.
nonisolated enum AgentDeliveryTargetPublicationBus {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var generation: UInt64 = 0

    static func publish() {
        condition.lock()
        generation &+= 1
        condition.broadcast()
        condition.unlock()
    }

    static func snapshot() -> UInt64 {
        condition.lock()
        let value = generation
        condition.unlock()
        return value
    }

    @discardableResult
    static func waitForChange(after observedGeneration: UInt64, until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while generation == observedGeneration {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

extension TerminalController {
    /// Waits for a claimed surface to appear in the app's authoritative owner
    /// index. The socket worker sleeps on a real topology signal, while each
    /// resolution attempt remains a short main-actor hop.
    nonisolated func v2AgentWaitForDeliveryTarget(
        params: [String: Any],
        timeout: TimeInterval = 0.8
    ) -> V2CallResult {
        guard v2UUID(params, "surface_id") != nil else {
            return v2MainSync { v2AgentResolveDeliveryTarget(params: params) }
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            let observedGeneration = AgentDeliveryTargetPublicationBus.snapshot()
            let result = v2MainSync {
                v2AgentResolveDeliveryTarget(params: params)
            }
            switch result {
            case .ok:
                return result
            case .err(let code, _, _) where code != "not_found":
                return result
            case .err:
                break
            }
            guard Date() < deadline else { return result }
            _ = AgentDeliveryTargetPublicationBus.waitForChange(
                after: observedGeneration,
                until: deadline
            )
        }
    }
}
