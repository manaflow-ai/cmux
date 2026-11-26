internal import Foundation

/// The command cmux types into an Eternal Terminal login shell to open a tmux control stream,
/// and the byte budget that line has to fit.
///
/// et types the command into a canonical-mode pty rather than exec'ing it, so the budget is a
/// hard delivery limit: a longer line never completes, the shell runs nothing, and the attach
/// dies on a timeout with nothing to explain it. The socket boundary and the spawn gate both
/// measure the rendered line through this type, so a line that fits one fits the other.
///
/// ```swift
/// let line = RemoteTmuxETCommandLine(
///     tmuxArguments: ["-CC", "attach-session", "-t", "work"], socketName: "alpha")
/// line.rendered   // 'tmux' '-L' 'alpha' '-CC' 'attach-session' '-t' 'work'
/// line.overrun    // nil while the line fits
/// ```
public struct RemoteTmuxETCommandLine: Sendable, Equatable {
    /// Longest line a remote login shell will accept: `MAX_CANON`, which is 1024 on macOS.
    ///
    /// The value is the smaller of the platforms cmux reaches, deliberately. It is 4096 on
    /// Linux, so a bound of 1024 is safe against either, but only as a starting figure,
    /// because the whole line is not cmux's to spend. See ``deliverableCommandBytes``.
    public static let maxCanonicalLineBytes = 1024

    /// The part of the line et and the shell spend before cmux's command starts.
    ///
    /// Measured, because assuming the whole line was available was wrong: against et 6.2.11+7
    /// on macOS, delivery stops between 953 and 1016 bytes, not at 1024. et appends `; exit`
    /// to whatever it is given and the shell's own line editing costs more on top, so roughly
    /// 70 bytes of a 1024-byte line are already spent. The allowance is rounded up from the
    /// measured 71 bytes to absorb a longer prompt or a noisier shell.
    /// `scripts/remote-tmux-et-conformance.sh` re-measures the real threshold on each run and
    /// fails if this budget no longer fits inside it.
    public static let transportLineOverheadAllowanceBytes = 96

    /// Bytes available for the remote command itself.
    public static var deliverableCommandBytes: Int {
        max(0, maxCanonicalLineBytes - transportLineOverheadAllowanceBytes)
    }

    /// The tmux arguments after any server selection, session name included.
    public let tmuxArguments: [String]
    /// The tmux server name (`-L <name>`), or `nil` for the default server.
    public let socketName: String?

    /// Creates the line for one tmux argument vector on one tmux server.
    public init(tmuxArguments: [String], socketName: String? = nil) {
        self.tmuxArguments = tmuxArguments
        self.socketName = socketName
    }

    /// The line as typed: `tmux`, the server selection, then the arguments, each single-quoted.
    ///
    /// Every word is quoted, so a session name the shell would otherwise glob or split still
    /// names the session. Quoting counts against the budget: a `'` in a word costs three extra
    /// bytes on the wire.
    public var rendered: String {
        (["tmux"] + RemoteTmuxSocketName.arguments(for: socketName) + tmuxArguments)
            .map(Self.shellSingleQuoted)
            .joined(separator: " ")
    }

    /// How far ``rendered`` runs past ``deliverableCommandBytes``, or `nil` when it fits. A
    /// line of exactly the budget fits.
    public var overrun: (actual: Int, budget: Int)? {
        let actual = rendered.utf8.count
        let budget = Self.deliverableCommandBytes
        return actual > budget ? (actual: actual, budget: budget) : nil
    }

    /// `value` as one POSIX-shell word: wrapped in single quotes, with each embedded `'`
    /// closed, escaped and reopened.
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
