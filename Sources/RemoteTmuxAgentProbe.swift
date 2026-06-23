import Foundation

/// Pure builder + parser for the remote `~/.claude` activity probe that enriches
/// a remote-tmux agent chip with busy/idle and model (Attempt 2 in
/// `docs/investigations/remote-agent-status-sidebar.md`).
///
/// The mirror already knows a pane's working directory (`pane_current_path`, the
/// `cmux_cwd_` subscription). Claude derives its transcript directory name from
/// the cwd by replacing `/` and `.` with `-`
/// (``RestorableAgentSessionIndex/encodeClaudeProjectDir(_:)``), and appends each
/// session's events to `~/.claude/projects/<dir>/<sessionId>.jsonl` in real time.
/// So from the cwd alone — no remote PID needed — we can read the newest
/// transcript's mtime (a busy/idle proxy) and its last assistant `message.model`.
///
/// This type owns only the *shell command* and the *output parse*; the async
/// exec + throttling live in the mirror. Both are pure and unit-tested, because
/// they are the correctness-critical pieces (the remote tmux exposes the comm
/// name but never the agent's busy/idle or model — those come only from here).
enum RemoteTmuxAgentProbe {
    /// Seconds since a transcript's last write within which the agent is treated
    /// as "working". A long tool call can briefly exceed this; the chip then reads
    /// "idle" until the next transcript append. Chosen generous enough to ride
    /// short gaps, short enough that a finished session goes idle promptly.
    static let busyWindowSeconds = 30

    /// Field separator in the probe's single-line stdout. A unit separator never
    /// appears in a model id, an epoch integer, or a transcript path.
    static let fieldSeparator = "\u{1f}"

    /// Builds the remote `["sh", "-c", <script>]` argv that probes the Claude
    /// transcript for `cwd`. The script:
    ///   1. derives the project-dir name from `cwd` (the same `/`+`.`→`-` rule),
    ///   2. finds the newest `*.jsonl` under `~/.claude/projects/<dir>`,
    ///   3. prints `<nowEpoch><US><mtimeEpoch><US><newestPath>` (one line),
    /// portably across GNU/BSD `stat` (tries `-c %Y`, falls back to `-f %m`).
    ///
    /// The model is parsed in a *second* step (`tailCommand`) only when busy, to
    /// keep the hot probe cheap. Returns `nil` for an empty/space-only cwd.
    static func activityProbeCommand(cwd: String) -> [String]? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dir = encodeProjectDir(trimmed)
        // Single-quote the dir for safe embedding; the whole script is one arg.
        let q = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let sep = fieldSeparator
        let script = """
        d="$HOME/.claude/projects/\(q)"; \
        n=$(ls -t "$d"/*.jsonl 2>/dev/null | head -1); \
        [ -z "$n" ] && exit 0; \
        m=$(stat -c %Y "$n" 2>/dev/null || stat -f %m "$n" 2>/dev/null); \
        printf '%s\(sep)%s\(sep)%s' "$(date +%s)" "$m" "$n"
        """
        return ["sh", "-c", script]
    }

    /// Builds the remote argv that reads the model from a transcript's last
    /// assistant line. `tail`-then-grep keeps it to the final lines; the caller
    /// passes the `transcriptPath` returned by the activity probe.
    static func modelProbeCommand(transcriptPath: String) -> [String]? {
        let trimmed = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let q = "'" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Last 40 lines, last occurrence of a model field; sed extracts the value.
        let script = """
        tail -n 40 \(q) 2>/dev/null \
        | grep -o '\"model\":\"[^\"]*\"' | tail -1 \
        | sed 's/.*\"model\":\"//; s/\"$//'
        """
        return ["sh", "-c", script]
    }

    /// Parsed result of the activity probe.
    struct Activity: Equatable {
        let busy: Bool
        let transcriptPath: String
    }

    /// Parses `activityProbeCommand` stdout. `nil` when there is no transcript
    /// (empty stdout) or the line is malformed — caller treats that as "no
    /// transcript activity to show".
    static func parseActivity(stdout: String) -> Activity? {
        let line = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let fields = line.components(separatedBy: fieldSeparator)
        guard fields.count >= 3,
              let now = Int(fields[0].trimmingCharacters(in: .whitespaces)),
              let mtime = Int(fields[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let path = fields[2...].joined(separator: fieldSeparator)
        guard !path.isEmpty else { return nil }
        // A clock skew between the probe's `date +%s` and the file's mtime can make
        // (now - mtime) negative; a write at-or-ahead of "now" is the freshest
        // possible, so clamp negative ages to busy rather than reading them idle.
        let age = now - mtime
        return Activity(busy: age <= busyWindowSeconds, transcriptPath: path)
    }

    /// Parses `modelProbeCommand` stdout into a trimmed model id, or `nil`.
    /// Strips the `[1m]` "1 month retention" suffix the way the local Claude
    /// metadata parser does (`SessionIndexStore.extractClaudeMetadata`).
    static func parseModel(stdout: String) -> String? {
        var model = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        if model.hasSuffix("[1m]") { model.removeLast(4) }
        model = model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }

    /// The Claude project-dir name for a cwd — same rule as
    /// ``RestorableAgentSessionIndex/encodeClaudeProjectDir(_:)`` (kept local so
    /// this pure helper has no dependency on that type).
    static func encodeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
