import Foundation

/// Identifies the rule chain that caused an action-generated event.
///
/// The chain is carried in the event envelope rather than in a user payload,
/// so ordinary event consumers can ignore it while the automation engine can
/// stop direct and indirect cycles deterministically.
nonisolated struct CmuxAutomationEventOrigin: Codable, Equatable, Sendable {
    let ruleID: String
    let chain: [String]

    init(ruleID: String, chain: [String]) {
        self.ruleID = ruleID
        self.chain = chain
    }

    var foundationObject: [String: Any] {
        [
            "rule_id": ruleID,
            "chain": chain,
            "depth": chain.count
        ]
    }
}

/// Task-local metadata shared by the dispatcher and event bus.
///
/// Task-local values avoid process-global flags when two automation actions
/// run concurrently. The existing v2 dispatcher already propagates its focus
/// allowance stack across main-actor hops; the values here complement that
/// stack for actions originating in the in-process engine.
// TaskLocal storage is necessarily type-scoped; this enum is only the binding
// key and intentionally has no instances or domain behavior.
enum CmuxAutomationInvocationContext {
    @TaskLocal static var focusAllowed: Bool?
    @TaskLocal static var eventOrigin: CmuxAutomationEventOrigin?
}
