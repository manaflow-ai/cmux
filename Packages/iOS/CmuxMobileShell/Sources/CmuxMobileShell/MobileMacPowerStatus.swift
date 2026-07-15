import Foundation

public struct MobileMacPowerStatus: Equatable, Sendable {
    public let keepAwakeEnabled: Bool
    public let lowPowerEnabled: Bool

    static func decode(_ data: Data) throws -> MobileMacPowerStatus {
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard envelope?["ok"] as? Bool == true,
              let result = envelope?["result"] as? [String: Any],
              let keepAwake = result["keep_awake_enabled"] as? Bool,
              let lowPower = result["low_power_enabled"] as? Bool else {
            throw MobileMacPowerError.invalidResponse
        }
        return MobileMacPowerStatus(
            keepAwakeEnabled: keepAwake,
            lowPowerEnabled: lowPower
        )
    }
}
