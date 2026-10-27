import CmuxNextActions
import CmuxNextCompat
import Foundation

/// Where `cmux window|pane|tab screenshot` puts the PNG: its `out` argument.
enum ScreenshotOutput: Equatable {
    /// An absolute file path (`~` expanded); parent folders are created.
    case file(URL)
    /// `-`: the PNG inline in the result as `png_base64`, or in a temporary
    /// file (`path`) when it is too large for one control-socket answer.
    case inline
    /// Omitted: a file in the temporary directory, named in `path`.
    case temporary

    /// The output `invocation` asks for.
    /// - Throws: ``ActionFailure`` naming what is wrong with `out`.
    init(_ invocation: ActionInvocation) throws {
        guard let value = invocation["out"] else {
            self = .temporary
            return
        }
        guard let text = value.stringValue else { throw ActionFailure(message: ScreenshotStrings.outNeedsValue) }
        try self.init(out: text, isDirectory: Self.isDirectory)
    }

    /// Parses an `out` value; `isDirectory` says whether a path names an
    /// existing folder (injected so tests need no file system).
    init(out text: String, isDirectory: (String) -> Bool) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ActionFailure(message: ScreenshotStrings.outNeedsValue) }
        if trimmed == "-" {
            self = .inline
            return
        }
        let path = (trimmed as NSString).expandingTildeInPath
        // The app runs elsewhere than the caller: the cmux CLI makes a relative
        // path absolute before it sends it; any other caller must.
        guard path.hasPrefix("/") else { throw ActionFailure(message: ScreenshotStrings.outRelative(trimmed)) }
        // `expandingTildeInPath` drops a trailing slash, so check the text.
        guard !trimmed.hasSuffix("/"), !isDirectory(path) else { throw ActionFailure(message: ScreenshotStrings.outIsFolder(trimmed)) }
        self = .file(URL(fileURLWithPath: path).standardizedFileURL)
    }

    private static func isDirectory(_ path: String) -> Bool {
        FileManager.default.directoryExists(atPath: path)
    }
}
