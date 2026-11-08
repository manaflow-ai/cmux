import Foundation

/// A failed mount's reason, split for its error card: what went wrong, and where in the script.
///
/// The supervisor reports a script that does not load as
/// `init: main: Error: expecting ';' at main.js:2:12`. The card shows `expecting ';'` and
/// `main.js:2:12` on their own lines, so the line to fix stands out and the plumbing words do not.
struct AppScriptFailure: Equatable, Sendable {
    /// The reason without its location and the supervisor's `init:` / `main:` / `Error:` prefixes.
    let message: String
    /// `file:line[:column]` the reason names, nil when it names none.
    let location: String?

    init(reason: String) {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = /(?:\s+at\s+|\s*\(|\s+)?([A-Za-z0-9_.\/-]+\.(?:js|mjs|cjs)|eval_script):(\d+)(?::(\d+))?\)?/
        var location: String?
        if let match = text.matches(of: pattern).last {
            let (_, file, line, column) = match.output
            location = column.map { "\(file):\(line):\($0)" } ?? "\(file):\(line)"
            text.removeSubrange(match.range)
        }
        for prefix in ["init: ", "main: ", "Error: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message.isEmpty ? reason : message
        self.location = location
    }
}
