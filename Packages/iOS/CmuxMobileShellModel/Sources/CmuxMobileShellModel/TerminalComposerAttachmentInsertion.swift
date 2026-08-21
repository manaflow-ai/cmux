import Foundation

/// Produces one shell-safe terminal draft fragment for an uploaded attachment's
/// Mac path. Used by the composer submit path to reference staged files in the
/// sent message.
public struct TerminalComposerAttachmentInsertion: Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func appending(to draft: String) -> String {
        var result = draft
        if !result.isEmpty, result.last?.isWhitespace == false {
            result += " "
        }
        result += "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' "
        return result
    }
}
