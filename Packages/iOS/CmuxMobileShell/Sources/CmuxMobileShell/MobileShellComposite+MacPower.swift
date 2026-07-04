internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

nonisolated private let macPowerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-mac-power"
)

/// Wrapper for the `mac.power.keep_awake.disable` result `{ terminated_caffeinate, status }`.
private struct MobileMacKeepAwakeDisableResponse: Decodable {
    let status: MobileMacPowerStatus

    private enum CodingKeys: String, CodingKey {
        case status
    }
}

// MARK: - Mac power control RPCs

extension MobileShellComposite {
    /// Read the connected Mac's keep-awake status. Returns `nil` if the Mac is
    /// unreachable or the status could not be decoded.
    public func macPowerStatus(macDeviceID: String? = nil) async -> MobileMacPowerStatus? {
        guard let client = macPowerClient(for: macDeviceID) else { return nil }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mac.power.status",
                params: ["client_id": clientID]
            )
            let data = try await client.sendRequest(request)
            return try? JSONDecoder().decode(MobileMacPowerStatus.self, from: data)
        } catch {
            _ = disconnectForAuthorizationFailureIfNeeded(error)
            macPowerLog.error("mac.power.status failed error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Put the connected Mac to sleep.
    public func sleepMac(macDeviceID: String? = nil) async -> MobileMacSleepResult {
        guard let client = macPowerClient(for: macDeviceID) else { return .failed }
        let request: Data
        do {
            request = try MobileCoreRPCClient.requestData(
                method: "mac.power.sleep",
                params: ["client_id": clientID]
            )
        } catch {
            macPowerLog.error("mac.power.sleep request build failed error=\(String(describing: error), privacy: .public)")
            return .failed
        }
        do {
            _ = try await client.sendRequest(request)
            return .requested
        } catch {
            if disconnectForAuthorizationFailureIfNeeded(error) { return .failed }
            let result = MobileMacSleepErrorClassifier().result(forSendError: error)
            switch result {
            case .requested:
                break
            case .refused:
                // The Mac answered with an explicit error (e.g. Automation access
                // not granted yet): a genuine refusal, the Mac did not sleep.
                break
            case .failed:
                macPowerLog.error("mac.power.sleep send failed error=\(String(describing: error), privacy: .public)")
            }
            return result
        }
    }

    /// Disable active keep-awake (terminate caffeinate) on the connected Mac, and
    /// return the fresh status so the caller can reflect whatever still holds it
    /// awake. Returns `nil` if the Mac is unreachable.
    public func disableMacKeepAwake(macDeviceID: String? = nil) async -> MobileMacPowerStatus? {
        guard let client = macPowerClient(for: macDeviceID) else { return nil }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mac.power.keep_awake.disable",
                params: ["client_id": clientID]
            )
            let data = try await client.sendRequest(request)
            return try? JSONDecoder().decode(MobileMacKeepAwakeDisableResponse.self, from: data).status
        } catch {
            _ = disconnectForAuthorizationFailureIfNeeded(error)
            macPowerLog.error("mac.power.keep_awake.disable failed error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Resolve the RPC client that owns `macDeviceID`. Power commands target the
    /// Mac the phone is actually connected to; an empty/absent id uses the
    /// foreground connection (mirrors the workspace/notification routing).
    private func macPowerClient(for macDeviceID: String?) -> MobileCoreRPCClient? {
        guard let macDeviceID, !macDeviceID.isEmpty else { return remoteClient }
        if foregroundMacDeviceID == macDeviceID { return remoteClient }
        return secondaryMacSubscriptions[macDeviceID]?.client
    }
}
