/// The name of a tmux server selected with `tmux -L <name>` (#15022).
///
/// The value is interpolated into a remote shell command, so instead of relying on quoting
/// it is held to a strict spelling that both the CLI and the app's socket boundary enforce:
/// ASCII letters, digits, `.`, `_` and `-`, 1 to 64 characters, not starting with `-` (a
/// leading dash reads as a flag everywhere the name is typed), and never `.` or `..`, which
/// name the socket directory rather than a socket in it. tmux places the server's socket at
/// `$TMUX_TMPDIR/tmux-<uid>/<name>`, so the length cap keeps that path well inside the
/// AF_UNIX limit on any sane temp directory.
public enum RemoteTmuxSocketName {
    /// Longest accepted name, in characters (all ASCII, so also bytes).
    public static let maxLength = 64

    /// The name tmux gives its default server: `tmux -L default` and no `-L` at all open the
    /// same socket, so cmux treats them as one endpoint (see ``normalized(_:)``).
    public static let defaultName = "default"

    /// `nil` when `name` means the default server, otherwise `name` unchanged.
    ///
    /// Applied where a host is built, so the connection hash, the ControlMaster socket and the
    /// `-L` prefix all agree that `--socket-name default` is the server the flag's absence names.
    public static func normalized(_ name: String?) -> String? {
        guard let name, name != defaultName else { return nil }
        return name
    }

    /// Whether `name` is a spelling cmux will pass to `tmux -L`.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxLength, !name.hasPrefix("-"),
              name != ".", name != ".." else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    /// The tmux arguments that select the server: `-L <name>`, or nothing for the default.
    ///
    /// One definition, so the ssh resolver wrapper and the Eternal Terminal login-shell line
    /// cannot disagree about how a server is named.
    public static func arguments(for name: String?) -> [String] {
        guard let name else { return [] }
        return ["-L", name]
    }
}
