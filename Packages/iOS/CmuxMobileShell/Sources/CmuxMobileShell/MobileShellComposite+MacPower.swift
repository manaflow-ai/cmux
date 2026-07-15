import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    public var supportsMacPowerControl: Bool {
        supportedHostCapabilities.contains(Self.macPowerCapability)
    }

    public func macPowerStatus() async throws -> MobileMacPowerStatus {
        try await sendMacPowerRequest(method: "mac.power.status", params: [:])
    }

    public func sleepMacDisplay() async throws {
        guard supportsMacPowerControl, let remoteClient else { throw MobileMacPowerError.unavailable }
        let request = try MobileCoreRPCClient.requestData(method: "mac.power.sleep_display", params: [:])
        _ = try await remoteClient.sendRequest(request)
    }

    public func setMacKeepAwake(_ enabled: Bool) async throws -> MobileMacPowerStatus {
        try await sendMacPowerRequest(
            method: "mac.power.keep_awake.set", params: ["enabled": enabled]
        )
    }

    public func setMacLowPowerMode(_ enabled: Bool) async throws -> MobileMacPowerStatus {
        try await sendMacPowerRequest(
            method: "mac.power.low_power.set", params: ["enabled": enabled]
        )
    }

    private func sendMacPowerRequest(
        method: String, params: [String: Any]
    ) async throws -> MobileMacPowerStatus {
        guard supportsMacPowerControl, let remoteClient else { throw MobileMacPowerError.unavailable }
        let request = try MobileCoreRPCClient.requestData(method: method, params: params)
        let response = try await remoteClient.sendRequest(request)
        return try MobileMacPowerStatus.decode(response)
    }
}
