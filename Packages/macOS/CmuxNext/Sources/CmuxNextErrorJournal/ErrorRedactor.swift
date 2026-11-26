/// Removes secrets from text before it is journaled: auth headers, cookies, bearer and API
/// tokens, JWTs, URL credentials and secret query values, and long opaque blobs. The rules are
/// Rust's (`cmux-error-journal` `redact`); a text Rust did not answer for is withheld whole.
///
/// ```swift
/// ErrorRedactor().redact("Authorization: Bearer abc.def") // "Authorization=<redacted>"
/// ```
public struct ErrorRedactor {
    /// Makes a redactor.
    public init() {}

    /// Returns `text` with every secret replaced by `<redacted>`.
    public func redact(_ text: String) -> String {
        ErrorJournalFFI.object("error_journal_redact", ["text": text])?["text"] as? String ?? "<redacted>"
    }
}
