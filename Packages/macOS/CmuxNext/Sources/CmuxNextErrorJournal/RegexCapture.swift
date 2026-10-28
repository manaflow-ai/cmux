import Foundation

extension NSTextCheckingResult {
    /// The text of capture group `group` in `text`, the string this match was found in, or nil when the group
    /// took no part in the match. The text is a log line or a report a file held, so it is cut by UTF-16
    /// counts from the front, which never trap (p10-stability.md, section D: outside input never traps).
    func capture(_ group: Int, in text: String) -> String? {
        let span = self.range(at: group)
        guard span.location != NSNotFound else { return nil }
        return String(decoding: text.utf16.dropFirst(span.location).prefix(span.length), as: UTF16.self)
    }

    /// The text of `text` after capture group `group`, or nil when the group took no part in the match.
    func text(after group: Int, in text: String) -> String? {
        let span = self.range(at: group)
        guard span.location != NSNotFound else { return nil }
        return String(decoding: text.utf16.dropFirst(span.location).dropFirst(span.length), as: UTF16.self)
    }
}
