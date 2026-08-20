#if os(iOS)
import Foundation

/// Produces one shell-safe terminal draft after a file upload returns its Mac path.
struct TerminalComposerAttachmentInsertion: Equatable, Sendable {
    let path: String

    func appending(to draft: String) -> String {
        var result = draft
        if !result.isEmpty, result.last?.isWhitespace == false {
            result += " "
        }
        result += "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' "
        return result
    }
}
#endif
