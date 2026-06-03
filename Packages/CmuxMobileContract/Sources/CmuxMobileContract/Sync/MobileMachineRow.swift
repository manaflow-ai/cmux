import Foundation

/// A machine row returned by the mobile sync API.
///
/// This is a pure wire DTO. Mapping a machine row into a terminal host is a domain concern and
/// lives in the terminal domain layer, not on this type.
public struct MobileMachineRow: Codable, Equatable, Sendable, Identifiable {
    /// The team identifier the machine belongs to.
    public let teamId: String

    /// The user identifier the machine belongs to.
    public let userId: String

    /// The machine identifier.
    public let machineId: String

    /// The human-readable display name.
    public let displayName: String

    /// The Tailscale hostname, if any.
    public let tailscaleHostname: String?

    /// The machine's Tailscale IP addresses.
    public let tailscaleIPs: [String]

    /// The machine's reachability status.
    public let status: MobileMachineStatus

    /// The last-seen time as a Unix timestamp.
    public let lastSeenAt: Double

    /// The last workspace-sync time as a Unix timestamp, if any.
    public let lastWorkspaceSyncAt: Double?

    /// The WebSocket port for direct daemon connection, if available.
    public let wsPort: Int?

    /// The WebSocket secret for direct daemon connection, if available.
    public let wsSecret: String?

    /// The stable identity, equal to ``machineId``.
    public var id: String { machineId }

    /// Creates a machine row.
    ///
    /// - Parameters:
    ///   - teamId: The team identifier the machine belongs to.
    ///   - userId: The user identifier the machine belongs to.
    ///   - machineId: The machine identifier.
    ///   - displayName: The human-readable display name.
    ///   - tailscaleHostname: The Tailscale hostname, if any.
    ///   - tailscaleIPs: The machine's Tailscale IP addresses.
    ///   - status: The machine's reachability status.
    ///   - lastSeenAt: The last-seen time as a Unix timestamp.
    ///   - lastWorkspaceSyncAt: The last workspace-sync time as a Unix timestamp, if any.
    ///   - wsPort: The WebSocket port for direct daemon connection, if available.
    ///   - wsSecret: The WebSocket secret for direct daemon connection, if available.
    public init(
        teamId: String,
        userId: String,
        machineId: String,
        displayName: String,
        tailscaleHostname: String?,
        tailscaleIPs: [String],
        status: MobileMachineStatus,
        lastSeenAt: Double,
        lastWorkspaceSyncAt: Double?,
        wsPort: Int?,
        wsSecret: String?
    ) {
        self.teamId = teamId
        self.userId = userId
        self.machineId = machineId
        self.displayName = displayName
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPs = tailscaleIPs
        self.status = status
        self.lastSeenAt = lastSeenAt
        self.lastWorkspaceSyncAt = lastWorkspaceSyncAt
        self.wsPort = wsPort
        self.wsSecret = wsSecret
    }

    /// The preferred network address: Tailscale hostname, then first IP, then machine id.
    public var preferredAddress: String {
        if let tailscaleHostname,
           !tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tailscaleHostname
        }
        if let firstIP = tailscaleIPs.first,
           !firstIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstIP
        }
        return machineId
    }

    /// The preferred server identifier: Tailscale hostname when present, otherwise machine id.
    public var preferredServerID: String {
        let trimmedHostname = tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedHostname.isEmpty {
            return trimmedHostname
        }
        return machineId
    }
}
