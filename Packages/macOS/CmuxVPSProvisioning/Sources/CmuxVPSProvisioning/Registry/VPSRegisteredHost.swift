internal import Foundation

/// One registered BYO VPS host as persisted in the local registry.
///
/// Field names are the on-disk JSON wire shape; renaming is a migration.
public struct VPSRegisteredHost: Equatable, Sendable, Codable {
    /// Connection identity (destination, port, identity file, ssh options).
    public var host: VPSHostDescriptor
    /// Optional user-facing display name.
    public var name: String?
    /// Shared persistent-daemon slot workspaces on this host attach to.
    public var slot: String
    /// systemd scope the unit was installed into, `nil` on non-systemd hosts.
    public var unitScope: VPSUnitScope?
    /// Daemon version most recently installed by this client.
    public var installedVersion: String
    /// Remote GOOS recorded at provision time.
    public var goOS: String
    /// Remote GOARCH recorded at provision time.
    public var goArch: String
    /// Distro `ID` recorded at provision time (may be empty).
    public var distroID: String
    /// Unix seconds when the host was first registered.
    public var addedAtUnix: Int
    /// Unix seconds of the last successful provision/upgrade/status check.
    public var lastSeenAtUnix: Int?

    enum CodingKeys: String, CodingKey {
        case host
        case name
        case slot
        case unitScope = "unit_scope"
        case installedVersion = "installed_version"
        case goOS = "go_os"
        case goArch = "go_arch"
        case distroID = "distro_id"
        case addedAtUnix = "added_at_unix"
        case lastSeenAtUnix = "last_seen_at_unix"
    }

    /// Creates a registry entry.
    public init(
        host: VPSHostDescriptor,
        name: String? = nil,
        slot: String = VPSRemoteLayout.sharedSlot,
        unitScope: VPSUnitScope? = nil,
        installedVersion: String,
        goOS: String,
        goArch: String,
        distroID: String = "",
        addedAtUnix: Int,
        lastSeenAtUnix: Int? = nil
    ) {
        self.host = host
        self.name = name
        self.slot = slot
        self.unitScope = unitScope
        self.installedVersion = installedVersion
        self.goOS = goOS
        self.goArch = goArch
        self.distroID = distroID
        self.addedAtUnix = addedAtUnix
        self.lastSeenAtUnix = lastSeenAtUnix
    }
}
