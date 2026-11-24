/// Reads the stderr of a failed remote tmux command and says which failure it describes.
///
/// tmux reports an idle server and an unreachable one with similar text, so the two readings
/// live together: an overlong socket path is checked first and is never an idle server. The
/// app's transport decides what each answer means (an empty session list, or a failure with
/// cmux's own wording); this type only classifies the text.
public struct RemoteTmuxFailureClassifier: Sendable, Equatable {
    /// The stderr being classified, lowercased once for the substring checks.
    private let lowered: String

    /// Classifies `stderr` from a failed remote tmux command.
    public init(stderr: String) {
        lowered = stderr.lowercased()
    }

    /// Whether tmux refused its own socket path as too long.
    ///
    /// tmux prints `error connecting to <socket> (File name too long)` when the socket path
    /// (`$TMUX_TMPDIR/tmux-<uid>/<name>`) exceeds the AF_UNIX limit, which a long `-L <name>`
    /// under a long `TMUX_TMPDIR` can reach.
    ///
    /// The reason is read from the end of the diagnostic line, so a socket path that happens to
    /// contain the words (`/tmp/file name too long/…`) with another reason, such as
    /// `(Permission denied)`, is not taken for this failure.
    public var indicatesSocketPathTooLong: Bool {
        lowered.split(whereSeparator: \.isNewline).contains { line in
            guard line.contains("error connecting to") else { return false }
            let end = line.lastIndex { !$0.isWhitespace } ?? line.startIndex
            return line[...end].hasSuffix("(file name too long)")
        }
    }

    /// Whether the remote tmux server simply isn't running.
    ///
    /// An overlong socket path (``indicatesSocketPathTooLong``) is excluded: that server can
    /// never be contacted, so reading it as idle would turn the failure into an empty session
    /// list.
    public var indicatesNoServer: Bool {
        if indicatesSocketPathTooLong { return false }
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || (lowered.contains("error connecting to /") && lowered.contains("/tmux-"))
    }
}
