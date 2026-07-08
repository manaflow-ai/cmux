import Foundation

/// Pure decision for whether cmux should hold the idle-sleep power assertion.
/// A value type (mirroring `MobileHostSyncDecision`) so the policy is
/// unit-testable without the manager's actor/singleton graph.
struct PreventSleepDecision {
    var agentsSettingEnabled: Bool
    var mobileSettingEnabled: Bool
    var runningAgentCount: Int
    var mobileConnectionCount: Int

    var isDesired: Bool {
        (agentsSettingEnabled && runningAgentCount > 0)
            || (mobileSettingEnabled && mobileConnectionCount > 0)
    }
}
