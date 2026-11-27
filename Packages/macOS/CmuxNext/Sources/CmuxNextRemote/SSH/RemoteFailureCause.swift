import Foundation

/// What a machine's raw failure (the remote daemon's or the link's words) means, for one plain
/// sentence on the Cannot Connect sheet; Copy Error keeps the raw text. User 2026-10-31 (Chief msg 19277):
/// the sheet showed lock paths, `try_lock` and `--session NAME`.
public nonisolated enum RemoteFailureCause: Equatable, Sendable {
    /// An older cmux-tui on the machine refused a session another daemon there (a Chief brain) owns.
    case sessionInUse
    /// The cause in a few words: the last `prefix: ` clause before any parenthesis or `; ` hint.
    case cause(String)
    /// Nothing short and path-free to say.
    case unknown

    public init(_ raw: String) {
        if raw.contains("in use by another cmux daemon") || raw.contains("already owned by another daemon") {
            self = .sessionInUse
            return
        }
        let head = raw.components(separatedBy: " (")[0].components(separatedBy: "; ")[0]
        let cause = (head.components(separatedBy: ": ").last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .;:\n"))
        self = cause.isEmpty || cause.contains("/") || cause.count > 120 ? .unknown : .cause(cause)
    }
}
