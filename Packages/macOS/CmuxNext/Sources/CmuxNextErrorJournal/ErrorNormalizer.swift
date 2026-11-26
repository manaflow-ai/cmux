/// Turns a message into its template: the stable text that names the same problem
/// whatever ids, numbers, paths or quoted values one occurrence carried (Rust's
/// `cmux-error-journal` `normalize`).
///
/// ```swift
/// ErrorNormalizer().template("took 512 ms for /Users/a/x.json") // "took <n> ms for <path>"
/// ```
public struct ErrorNormalizer {
    private let maxBytes: Int

    /// Makes a normalizer.
    /// - Parameter maxBytes: Most UTF-8 bytes of a template.
    public init(maxBytes: Int = 1024) {
        self.maxBytes = maxBytes
    }

    /// Returns the template of `message`; the message itself when Rust does not answer.
    public func template(_ message: String) -> String {
        ErrorJournalFFI.object("error_journal_template", ["message": message, "max_bytes": max(0, maxBytes)])?["template"]
            as? String ?? message
    }
}
