import Foundation

/// A bounded, JSON-friendly record retained by the automation firing ring.
nonisolated struct AutomationFiringRecord: Sendable {
    let occurredAt: Date
    let ruleID: String
    let eventName: String
    let status: String
    let detail: String
    let chain: [String]

    var payload: [String: Any] {
        [
            "occurred_at": CmuxEventBus.isoTimestamp(occurredAt),
            "rule_id": ruleID,
            "event": eventName,
            "status": status,
            "detail": detail,
            "chain": chain
        ]
    }
}
