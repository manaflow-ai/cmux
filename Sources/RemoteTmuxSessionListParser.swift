import Foundation

/// Parses the delimited output of `tmux list-sessions -F` into sessions.
///
/// The expected per-line format (set by ``RemoteTmuxSSHTransport``) is:
/// `#{session_id}:#{session_windows}:#{session_attached}:#{session_created}:#{session_name}`
///
/// `session_name` is placed **last** because it is the only free-text field;
/// the leading fields are a `$N` id, integer counts, and a unix timestamp, none
/// of which contain the `:` delimiter. The name is therefore parsed as the whole
/// remainder after the fourth delimiter, so a name is reproduced verbatim even
/// if it somehow contained a `:` (tmux already rewrites `:` in session names to
/// `_`, so this is defense in depth).
///
/// The delimiter is the printable `:` rather than a control character such as
/// tab: when the remote tmux client is not flagged UTF-8, tmux runs `-F` output
/// through `utf8_sanitize()`, which rewrites every non-printable-ASCII byte —
/// including tab — to `_`. The client is non-UTF-8 whenever the remote
/// `LC_ALL`/`LC_CTYPE`/`LANG` lacks "UTF-8" (and `$TMUX` is unset and `-u` is not
/// passed), which is the default on a non-interactive SSH command to a host with
/// no UTF-8 locale (e.g. Amazon Linux 2023). That collapsed the old tab-delimited
/// line into a single field and made every session unparseable. A printable
/// delimiter is preserved under any locale.
///
/// Parsing is deliberately lenient: malformed or short lines are skipped rather
/// than failing the whole listing, so a single odd session never hides the rest
/// of the sidebar.
enum RemoteTmuxSessionListParser {
    /// The field delimiter. A printable byte tmux preserves in `-F` output (it
    /// rewrites control bytes like tab to `_`), and one tmux forbids inside a
    /// session name (it rewrites `:` in names to `_`), so it cannot collide with
    /// any leading field value.
    static let fieldDelimiter = ":"

    /// Splits raw `tmux …list… -F` output (delimited with ``fieldDelimiter``) into
    /// rows of exactly `fieldCount` fields, where the LAST field is the free-text
    /// remainder (rejoined so an embedded delimiter is preserved). Strips a
    /// trailing `\r`, skips blank/short lines. Shared by every tmux `-F` row parser
    /// so the line-split / CR-strip / last-field-rejoin invariant lives in one place
    /// (the cross-host reason for the printable delimiter is documented above).
    static func splitRows(_ output: String, fieldCount: Int) -> [[String]] {
        precondition(fieldCount >= 1)
        // Split on any newline via `Character.isNewline`, which matches `\n`, `\r`,
        // AND the `\r\n` grapheme cluster. A plain `split(separator: "\n")` misses
        // `\r\n` (Swift clusters it as one Character, so it isn't equal to `\n`),
        // which previously left a stray `\r` on the last field of CRLF output.
        return output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine)
                if line.isEmpty { return nil }
                let fields = line.components(separatedBy: fieldDelimiter)
                guard fields.count >= fieldCount else { return nil }
                // Keep the first fieldCount-1 fields verbatim; rejoin the rest as the
                // trailing free-text field.
                var row = Array(fields[0..<(fieldCount - 1)])
                row.append(fields[(fieldCount - 1)...].joined(separator: fieldDelimiter))
                return row
            }
    }

    /// The `-F` format string this parser expects, ordered to match ``parse(_:)``
    /// with the free-text `session_name` last.
    static let formatString =
        "#{session_id}:#{session_windows}:#{session_attached}:#{session_created}:#{session_name}"

    /// Parses raw `list-sessions` stdout into structured sessions.
    ///
    /// - Parameter output: the raw stdout from the remote `tmux list-sessions`.
    /// - Returns: one ``RemoteTmuxSession`` per well-formed line, in input order.
    static func parse(_ output: String) -> [RemoteTmuxSession] {
        // Shared row split (id, windows, attached, created, name-remainder); the
        // name is the rejoined remainder so an embedded `:` survives.
        return splitRows(output, fieldCount: 5).compactMap { f in
            let id = f[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            return RemoteTmuxSession(
                id: id,
                name: f[4],
                windowCount: Int(f[1].trimmingCharacters(in: .whitespaces)) ?? 0,
                attached: (Int(f[2].trimmingCharacters(in: .whitespaces)) ?? 0) > 0,
                createdUnix: Int(f[3].trimmingCharacters(in: .whitespaces))
            )
        }
    }
}
