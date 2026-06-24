public import AppKit
public import Foundation

/// Records the pasteboard state captured right after the text box wrote a
/// temporary file URL, so a later restore can tell whether the pasteboard
/// still holds exactly that temporary write.
///
/// The text box, while pasting a file path into the terminal, temporarily
/// overwrites the general pasteboard with a single file URL. Before restoring
/// the user's original pasteboard contents it must confirm the pasteboard was
/// not changed by the user in the meantime; a stale restore would clobber the
/// user's clipboard. The token snapshots the pasteboard `changeCount` and the
/// standardized temporary `fileURL` at write time, and ``shouldRestore`` checks
/// the live pasteboard against it.
///
/// Design: the token is a pure ``Sendable`` value (an `Int` change count and a
/// `URL`). The file-URL decoding is not duplicated here; ``shouldRestore``
/// consults an injected ``ServiceFileURLReading`` (the same seam
/// ``ServiceOpenPasteboardResolver`` uses), so the concrete pasteboard-object
/// decoding stays behind one reader in the app target. The pasteboard-touching
/// members are `@MainActor` because ``ServiceFileURLReading`` is, and
/// `NSPasteboard` reads here originate on the main actor.
public struct TextBoxPasteboardRestorationToken: Equatable, Sendable {
    /// The pasteboard `changeCount` captured immediately after writing the
    /// temporary file URL.
    public let changeCount: Int

    /// The standardized temporary file URL that was written to the pasteboard.
    public let fileURL: URL

    /// Creates a restoration token from a captured change count and file URL.
    /// - Parameters:
    ///   - changeCount: The pasteboard `changeCount` at write time.
    ///   - fileURL: The standardized temporary file URL that was written.
    public init(changeCount: Int, fileURL: URL) {
        self.changeCount = changeCount
        self.fileURL = fileURL
    }

    /// Captures a token after a temporary file URL has been written to a
    /// pasteboard.
    /// - Parameters:
    ///   - fileURL: The file URL that was just written; stored standardized.
    ///   - pasteboard: The pasteboard whose current `changeCount` is recorded.
    /// - Returns: A token snapshotting that write.
    @MainActor
    public static func token(
        afterWritingTemporaryFileURL fileURL: URL,
        to pasteboard: NSPasteboard
    ) -> TextBoxPasteboardRestorationToken {
        TextBoxPasteboardRestorationToken(
            changeCount: pasteboard.changeCount,
            fileURL: fileURL.standardizedFileURL
        )
    }

    /// Reports whether `pasteboard` still holds exactly the temporary write
    /// recorded by `token`, so the original pasteboard contents may be restored.
    ///
    /// Returns `false` with no token. Otherwise the live pasteboard must carry
    /// the token's temporary file URL: when the change count is unchanged the
    /// write is intact; when it changed, restoration is still allowed only if
    /// the temporary URL is the pasteboard's sole file URL.
    /// - Parameters:
    ///   - pasteboard: The live pasteboard to inspect.
    ///   - token: The token captured at write time, if any.
    ///   - fileURLReader: The seam that reads the file URLs carried on the
    ///     pasteboard.
    /// - Returns: `true` when the recorded temporary write is still present.
    @MainActor
    public static func shouldRestore(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?,
        fileURLReader: any ServiceFileURLReading
    ) -> Bool {
        guard let token else {
            return false
        }
        let temporaryPath = token.fileURL.standardizedFileURL.path
        let currentFileURLPaths = Set(
            fileURLReader.fileURLs(from: pasteboard).map { $0.standardizedFileURL.path }
        )
        guard currentFileURLPaths.contains(temporaryPath) else {
            return false
        }
        guard pasteboard.changeCount == token.changeCount else {
            return currentFileURLPaths == [temporaryPath]
        }
        return true
    }

    /// Reports whether the pasteboard currently holds the temporary write
    /// recorded by `token`. Same predicate as ``shouldRestore``; named for the
    /// caller that re-snapshots the original pasteboard when the temporary write
    /// is no longer current.
    /// - Parameters:
    ///   - pasteboard: The live pasteboard to inspect.
    ///   - token: The token captured at write time, if any.
    ///   - fileURLReader: The seam that reads the file URLs carried on the
    ///     pasteboard.
    /// - Returns: `true` when the recorded temporary write is still present.
    @MainActor
    public static func isCurrentTemporaryWrite(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?,
        fileURLReader: any ServiceFileURLReading
    ) -> Bool {
        shouldRestore(pasteboard: pasteboard, token: token, fileURLReader: fileURLReader)
    }
}
