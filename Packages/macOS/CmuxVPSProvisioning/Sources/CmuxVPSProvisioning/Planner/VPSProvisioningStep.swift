/// One idempotent action in a provisioning plan, in execution order.
public enum VPSProvisioningStep: Equatable, Sendable {
    /// Upload the verified daemon binary to its versioned install path
    /// (temp upload, remote SHA-256 verification, `chmod 755`, atomic `mv`).
    case installBinary(version: String, remotePath: String)
    /// Point the stable `~/.cmux/vps/current` symlink at `target` atomically.
    case updateCurrentSymlink(target: String)
    /// Write the rendered systemd unit file at `path`.
    case writeUnitFile(path: String, scope: VPSUnitScope)
    /// `systemctl daemon-reload` after a unit file change.
    case daemonReload(scope: VPSUnitScope)
    /// `loginctl enable-linger` so a user-scope daemon survives logout.
    case enableLinger
    /// `systemctl enable` the unit for boot auto-start.
    case enableUnit(scope: VPSUnitScope)
    /// `systemctl restart` the unit (also serves as start when inactive).
    case restartUnit(scope: VPSUnitScope)
    /// End-to-end health check through the same stdio + Unix-socket path
    /// workspaces use, followed by a non-spawning `daemon-status` query.
    case verifyHealth
}
