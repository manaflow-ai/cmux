import Foundation

func preventSleepDesired(
    agentsSettingEnabled: Bool,
    mobileSettingEnabled: Bool,
    runningAgentCount: Int,
    mobileConnectionCount: Int
) -> Bool {
    (agentsSettingEnabled && runningAgentCount > 0)
        || (mobileSettingEnabled && mobileConnectionCount > 0)
}
