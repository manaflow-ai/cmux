internal import Foundation

/// On-host filesystem layout for a provisioned VPS backend.
///
/// The binary install path is the exact path the existing `cmux ssh`
/// bootstrap probes (`RemoteSessionCoordinator.remoteDaemonPath`), so a host
/// provisioned by `cmux vps add` never re-uploads the daemon when a regular
/// SSH workspace connects. Keep the two in lockstep.
public struct VPSRemoteLayout: Equatable, Sendable {
    /// Remote home directory (absolute, from the host probe).
    public var homeDirectory: String
    /// Daemon version segment used in install paths.
    public var version: String
    /// GOOS of the remote host (`linux`, `darwin`, `freebsd`).
    public var goOS: String
    /// GOARCH of the remote host (`amd64`, `arm64`, `arm`).
    public var goArch: String

    /// Name of the supervised persistent-daemon slot every VPS workspace on
    /// this host shares. Fixed so independent clients (or re-provisioning
    /// runs) converge on the same supervised daemon.
    public static let sharedSlot = "vps"

    /// systemd unit name installed by `cmux vps add`.
    public static let unitName = "cmux-vps.service"

    /// Creates a layout for one host + daemon version.
    ///
    /// - Parameters:
    ///   - homeDirectory: Absolute remote home directory.
    ///   - version: Daemon version path segment.
    ///   - goOS: Remote GOOS.
    ///   - goArch: Remote GOARCH.
    public init(homeDirectory: String, version: String, goOS: String, goArch: String) {
        self.homeDirectory = Self.normalizedHome(homeDirectory)
        self.version = version
        self.goOS = goOS
        self.goArch = goArch
    }

    /// Versioned daemon binary path, identical to the `cmux ssh` bootstrap
    /// install location: `~/.cmux/bin/cmuxd-remote/<version>/<goOS>-<goArch>/cmuxd-remote`.
    public var binaryPath: String {
        "\(homeDirectory)/.cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    /// Directory containing ``binaryPath``.
    public var binaryDirectory: String {
        "\(homeDirectory)/.cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)"
    }

    /// Root of installed daemon versions, one subdirectory per version.
    public var binaryVersionsRoot: String {
        "\(homeDirectory)/.cmux/bin/cmuxd-remote"
    }

    /// VPS-specific state directory (`~/.cmux/vps`).
    public var vpsDirectory: String {
        "\(homeDirectory)/.cmux/vps"
    }

    /// Stable symlink the systemd unit executes; upgrades atomically retarget
    /// it at the new versioned binary so the unit file never changes.
    public var currentSymlinkPath: String {
        "\(homeDirectory)/.cmux/vps/current"
    }

    /// Absolute unit file path for `scope`.
    public func unitFilePath(scope: VPSUnitScope) -> String {
        switch scope {
        case .user:
            return "\(homeDirectory)/.config/systemd/user/\(Self.unitName)"
        case .system:
            return "/etc/systemd/system/\(Self.unitName)"
        }
    }

    private static func normalizedHome(_ raw: String) -> String {
        var home = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while home.count > 1, home.hasSuffix("/") {
            home.removeLast()
        }
        return home
    }
}
