import Foundation

/// One tunnel this app build enrolled on the account's Cloud network: the
/// build's per-role device fingerprint and the role it serves.
///
/// Sign-out and `cmux vm tunnel revoke` delete exactly these tunnels. Every
/// build on a Mac shares one device id, so revoking by device id would also
/// end the Cloud access of other builds that are still signed in.
public struct CloudTunnelRole: Equatable, Sendable {
    public let deviceFingerprint: String
    public let purpose: VMTunnelManager.Purpose

    public init(deviceFingerprint: String, purpose: VMTunnelManager.Purpose) {
        self.deviceFingerprint = deviceFingerprint
        self.purpose = purpose
    }
}

extension VMTunnelManager {
    /// The tunnels this build has enrolled, read from disk without minting.
    /// Read before local credentials are removed: the fingerprints are the
    /// only record of which server-side tunnels belong to this build.
    ///
    /// - Parameter home: The home directory holding `~/.cmuxterm/wireguard`.
    /// - Returns: One role per purpose that has a stored fingerprint.
    public static func storedRoles(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> [CloudTunnelRole] {
        [Purpose.terminal, .browser].compactMap { purpose in
            VMTunnelManager(home: home, purpose: purpose).storedDeviceFingerprint().map {
                CloudTunnelRole(deviceFingerprint: $0, purpose: purpose)
            }
        }
    }
}

extension VMClient {
    public struct CloudTunnelRoleRevocationRequest: Sendable {
        public let path: String
        public let role: CloudTunnelRole

        /// Names one tunnel, never the Mac: the server then deletes that
        /// tunnel and leaves this Mac's access grant and other builds alone.
        public var body: [String: Any] {
            ["deviceFingerprint": role.deviceFingerprint, "tunnelPurpose": role.purpose.rawValue]
        }

        public var queryItems: [URLQueryItem] {
            [
                URLQueryItem(name: "deviceFingerprint", value: role.deviceFingerprint),
                URLQueryItem(name: "tunnelPurpose", value: role.purpose.rawValue),
            ]
        }

        public init(path: String, role: CloudTunnelRole) {
            self.path = path
            self.role = role
        }
    }

    public nonisolated static func tunnelRoleRevocationRequest(_ role: CloudTunnelRole) -> CloudTunnelRoleRevocationRequest {
        CloudTunnelRoleRevocationRequest(path: "/api/vm/tunnel", role: role)
    }
}
