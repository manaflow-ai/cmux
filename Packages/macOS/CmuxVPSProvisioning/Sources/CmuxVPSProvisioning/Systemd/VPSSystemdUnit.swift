internal import Foundation
internal import CryptoKit

/// Renders the systemd unit that supervises the shared VPS persistent daemon.
///
/// The unit executes the stable `~/.cmux/vps/current` symlink so upgrades
/// only retarget the symlink and restart the service; the unit file itself
/// stays byte-identical across versions. Drift is detected by comparing the
/// rendered content's SHA-256 with the probed on-host unit hash.
public struct VPSSystemdUnit: Equatable, Sendable {
    /// Host layout the unit is rendered for.
    public var layout: VPSRemoteLayout
    /// Scope the unit installs into.
    public var scope: VPSUnitScope

    /// Creates a unit renderer.
    ///
    /// - Parameters:
    ///   - layout: Host layout (home directory drives the ExecStart path).
    ///   - scope: User or system unit scope.
    public init(layout: VPSRemoteLayout, scope: VPSUnitScope) {
        self.layout = layout
        self.scope = scope
    }

    /// The rendered unit file content.
    ///
    /// `--idle-timeout 0` disables the daemon's empty-idle exit so the
    /// supervised daemon stays warm; systemd owns its lifecycle instead.
    /// The daemon binds only a per-user Unix socket — the unit opens no
    /// listening ports.
    public func fileContent() -> String {
        let wantedBy = scope == .user ? "default.target" : "multi-user.target"
        return """
        [Unit]
        Description=cmux remote daemon (persistent PTY sessions for cmux VPS workspaces)
        Documentation=https://github.com/manaflow-ai/cmux
        After=network.target

        [Service]
        Type=exec
        ExecStart=\(layout.currentSymlinkPath) serve --persistent-server --slot \(VPSRemoteLayout.sharedSlot) --idle-timeout 0
        Restart=on-failure
        RestartSec=2

        [Install]
        WantedBy=\(wantedBy)
        """ + "\n"
    }

    /// SHA-256 hex digest of ``fileContent()``, compared against the probed
    /// on-host unit hash to decide whether a rewrite is needed.
    public func contentSHA256() -> String {
        let digest = SHA256.hash(data: Data(fileContent().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
