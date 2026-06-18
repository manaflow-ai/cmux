import Foundation

/// Parses the tab-separated output of `tmux list-sessions -F` into sessions.
///
/// The expected per-line format (set by ``RemoteTmuxSSHTransport``) is:
/// `#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}`
///
/// Parsing is deliberately lenient: malformed or short lines are skipped
/// rather than failing the whole listing, so a single odd session name never
/// hides the rest of the sidebar.
enum RemoteTmuxSessionListParser {
    /// The `-F` format string this parser expects, ordered to match ``parse(_:)``.
    static let formatString = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}"

    /// Parses raw `list-sessions` stdout into structured sessions.
    ///
    /// - Parameter output: the raw stdout from the remote `tmux list-sessions`.
    /// - Returns: one ``RemoteTmuxSession`` per well-formed line, in input order.
    static func parse(_ output: String) -> [RemoteTmuxSession] {
        var sessions: [RemoteTmuxSession] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let fields = line.components(separatedBy: "\t")
            // Need at least id + name + windows; attached/created are optional.
            guard fields.count >= 3 else { continue }
            let id = fields[0].trimmingCharacters(in: .whitespaces)
            let name = fields[1]
            guard !id.isEmpty else { continue }
            let windowCount = Int(fields[2].trimmingCharacters(in: .whitespaces)) ?? 0
            let attached = fields.count >= 4
                && (Int(fields[3].trimmingCharacters(in: .whitespaces)) ?? 0) > 0
            let createdUnix: Int? = fields.count >= 5
                ? Int(fields[4].trimmingCharacters(in: .whitespaces)) : nil
            sessions.append(
                RemoteTmuxSession(
                    id: id,
                    name: name,
                    windowCount: windowCount,
                    attached: attached,
                    createdUnix: createdUnix
                )
            )
        }
        return sessions
    }
}
