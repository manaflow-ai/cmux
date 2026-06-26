internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let macPowerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-mac-power"
)

// MARK: - Wire models

/// One process keeping the Mac (or its display) awake, mirrored from the Mac's
/// `mac.power.status` result (`CmuxMacPower.MacPowerAssertionHolder`).
public struct MobileMacPowerHolder: Decodable, Sendable, Equatable, Identifiable {
    public let pid: Int
    public let processName: String
    public let assertionTypes: [String]
    public let detail: String?

    /// Stable per-row identity for SwiftUI lists.
    public var id: Int { pid }

    private enum CodingKeys: String, CodingKey {
        case pid
        case processName = "process"
        case assertionTypes = "types"
        case detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = (try container.decodeIfPresent(Int.self, forKey: .pid)) ?? 0
        processName = (try container.decodeIfPresent(String.self, forKey: .processName)) ?? ""
        assertionTypes = (try container.decodeIfPresent([String].self, forKey: .assertionTypes)) ?? []
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    public init(pid: Int, processName: String, assertionTypes: [String], detail: String?) {
        self.pid = pid
        self.processName = processName
        self.assertionTypes = assertionTypes
        self.detail = detail
    }
}

/// Whether the connected Mac is currently being kept awake, and by whom.
/// Mirrors the Mac's `mac.power.status` result
/// (`CmuxMacPower.MacKeepAwakeStatus`). The booleans drive a localized summary
/// on the phone; `holders` backs the per-process detail rows.
public struct MobileMacPowerStatus: Decodable, Sendable, Equatable {
    public let keptAwake: Bool
    public let preventsSystemSleep: Bool
    public let preventsDisplaySleep: Bool
    public let cmuxKeepingAwake: Bool
    public let caffeinateRunning: Bool
    public let holders: [MobileMacPowerHolder]

    private enum CodingKeys: String, CodingKey {
        case keptAwake = "kept_awake"
        case preventsSystemSleep = "prevents_system_sleep"
        case preventsDisplaySleep = "prevents_display_sleep"
        case cmuxKeepingAwake = "cmux_keeping_awake"
        case caffeinateRunning = "caffeinate_running"
        case holders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keptAwake = (try container.decodeIfPresent(Bool.self, forKey: .keptAwake)) ?? false
        preventsSystemSleep = (try container.decodeIfPresent(Bool.self, forKey: .preventsSystemSleep)) ?? false
        preventsDisplaySleep = (try container.decodeIfPresent(Bool.self, forKey: .preventsDisplaySleep)) ?? false
        cmuxKeepingAwake = (try container.decodeIfPresent(Bool.self, forKey: .cmuxKeepingAwake)) ?? false
        caffeinateRunning = (try container.decodeIfPresent(Bool.self, forKey: .caffeinateRunning)) ?? false
        holders = (try container.decodeIfPresent([MobileMacPowerHolder].self, forKey: .holders)) ?? []
    }

    public init(
        keptAwake: Bool,
        preventsSystemSleep: Bool,
        preventsDisplaySleep: Bool,
        cmuxKeepingAwake: Bool,
        caffeinateRunning: Bool,
        holders: [MobileMacPowerHolder]
    ) {
        self.keptAwake = keptAwake
        self.preventsSystemSleep = preventsSystemSleep
        self.preventsDisplaySleep = preventsDisplaySleep
        self.cmuxKeepingAwake = cmuxKeepingAwake
        self.caffeinateRunning = caffeinateRunning
        self.holders = holders
    }
}

/// Wrapper for the `mac.power.keep_awake.disable` result `{ terminated_caffeinate, status }`.
private struct MobileMacKeepAwakeDisableResponse: Decodable {
    let status: MobileMacPowerStatus

    private enum CodingKeys: String, CodingKey {
        case status
    }
}

/// The outcome of asking the Mac to sleep.
///
/// A sleep request usually drops the connection as the Mac sleeps, so a
/// connection error is NOT treated as a failure — only an explicit RPC error
/// (e.g. Automation permission not granted) is `refused`.
public enum MobileMacSleepResult: Sendable, Equatable {
    /// The Mac acknowledged the request, or the connection dropped as it slept.
    case requested
    /// The Mac explicitly refused (most often Automation access not granted).
    case refused
    /// The request could not be delivered (not connected / auth failure).
    case failed
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
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mac.power.sleep",
                params: ["client_id": clientID]
            )
            _ = try await client.sendRequest(request)
            return .requested
        } catch {
            if disconnectForAuthorizationFailureIfNeeded(error) { return .failed }
            // The Mac answered with an explicit error (e.g. Automation access not
            // granted yet): a genuine refusal, the Mac did not sleep.
            if let connectionError = error as? MobileShellConnectionError,
               case .rpcError = connectionError {
                return .refused
            }
            // A closed/timed-out connection right after asking the Mac to sleep is
            // the expected success signature — the Mac slept and the link dropped.
            macPowerLog.info("mac.power.sleep link dropped (treated as slept) error=\(String(describing: error), privacy: .public)")
            return .requested
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
