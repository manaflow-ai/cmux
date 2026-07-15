/// Which systemd manager owns the cmux VPS unit on the remote host.
///
/// Raw values appear in the on-disk registry and in `--json` CLI output; do
/// not rename cases.
public enum VPSUnitScope: String, Equatable, Sendable, Codable {
    /// Per-user unit under `~/.config/systemd/user`, managed with
    /// `systemctl --user`, kept alive across logouts via `loginctl
    /// enable-linger`. Used when the SSH user is not root.
    case user
    /// System unit under `/etc/systemd/system`, managed with plain
    /// `systemctl`. Used when the SSH user is root.
    case system

    /// The scope for a probed remote uid: root gets a system unit, everyone
    /// else a user unit.
    public static func forUID(_ uid: Int) -> VPSUnitScope {
        uid == 0 ? .system : .user
    }
}
