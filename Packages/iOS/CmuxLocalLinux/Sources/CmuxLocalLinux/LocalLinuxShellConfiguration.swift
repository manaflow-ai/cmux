public import Foundation

/// The single definition of how the local Linux shell is launched.
///
/// Busybox `login -f root` clears the environment except `TERM`, so the
/// entries below other than `TERM` only reach programs that skip `login`. The
/// baked rootfs sets `COLORTERM`, `LANG`, `EDITOR`, and `PATH` for login
/// shells in `/etc/profile.d/`, and this configuration keeps the same values
/// so a custom command sees an equivalent environment.
public nonisolated struct LocalLinuxShellConfiguration: Equatable, Sendable {
    /// argv for the session's first process. Empty is invalid.
    public var command: [String]
    /// `KEY=value` entries passed to that process.
    public var environment: [String]

    public init(command: [String], environment: [String]) {
        self.command = command
        self.environment = environment
    }

    /// A root login shell with a 256-color, truecolor-capable UTF-8 terminal.
    public static let `default` = LocalLinuxShellConfiguration(
        command: LocalLinuxRuntime.defaultCommand,
        environment: [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=C.UTF-8",
        ]
    )
}
