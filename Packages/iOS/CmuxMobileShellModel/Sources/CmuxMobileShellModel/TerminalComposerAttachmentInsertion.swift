import Foundation

/// Inserts one uploaded attachment's Mac path into a composer message as a
/// POSIX single-quoted token, so the receiving agent sees an unambiguous file
/// reference even when the name contains spaces or quotes.
///
/// Lives in the model package because the store quotes paths at send time
/// (the paths exist only after the send-time upload), while tests verify the
/// exact quoting without a store.
public struct TerminalComposerAttachmentInsertion: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The path wrapped in single quotes, with interior single quotes escaped
    /// as `'\''` (end quote, escaped quote, reopen quote).
    public var quotedPath: String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Appends the quoted path to `draft` with a single separating space and a
    /// trailing space, so successive insertions and the user's message stay
    /// whitespace-delimited: `"'a.txt' 'b.bin' message"`.
    public func appending(to draft: String) -> String {
        if draft.isEmpty {
            return quotedPath + " "
        }
        let separator = draft.last?.isWhitespace == true ? "" : " "
        return draft + separator + quotedPath + " "
    }
}
