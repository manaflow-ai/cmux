public import AppKit

/// Decides whether the text-box file-paste flow may restore the user's
/// original pasteboard contents after it temporarily wrote a file URL, and
/// mints the ``TextBoxPasteboardRestorationToken`` that records that write.
///
/// Isolation: `@MainActor` because it reads the live `NSPasteboard` through the
/// `@MainActor` ``ServiceFileURLReading`` seam, and every caller (the text-box
/// submission flow) already runs on the main actor. It holds only an immutable
/// injected reader, so it is a real value type with a constructor-injected
/// collaborator rather than a static utility namespace. The file-URL decoding
/// stays behind the seam (the app target's `PasteboardFileURLReader` also feeds
/// the terminal image-transfer path), so the app target supplies the conforming
/// reader at the composition root.
@MainActor
public struct TextBoxPasteboardRestorationGuard {
    private let fileURLReader: any ServiceFileURLReading

    /// Creates a restoration guard over a file-URL reading seam.
    /// - Parameter fileURLReader: Reads the file URLs carried directly on a
    ///   pasteboard; used to confirm the flow's own temporary write is still
    ///   present before restoring.
    public init(fileURLReader: any ServiceFileURLReading) {
        self.fileURLReader = fileURLReader
    }

    /// Mints a token recording a temporary file URL the flow just wrote to
    /// `pasteboard`.
    /// - Parameters:
    ///   - fileURL: The temporary file URL that was written.
    ///   - pasteboard: The pasteboard the write landed on.
    /// - Returns: A token stamping the standardized URL and the pasteboard's
    ///   current `changeCount`.
    public func token(
        afterWritingTemporaryFileURL fileURL: URL,
        to pasteboard: NSPasteboard
    ) -> TextBoxPasteboardRestorationToken {
        TextBoxPasteboardRestorationToken(
            changeCount: pasteboard.changeCount,
            fileURL: fileURL.standardizedFileURL
        )
    }

    /// Reports whether `pasteboard` still carries the temporary write recorded
    /// by `token`, meaning the flow's original contents may be restored.
    ///
    /// Returns `false` when there is no token. Otherwise the temporary file URL
    /// must still be present on the pasteboard; if the `changeCount` has since
    /// advanced, restoration is only allowed when that temporary URL is the sole
    /// file URL present (a user change would have added or replaced entries).
    /// - Parameters:
    ///   - pasteboard: The pasteboard to inspect.
    ///   - token: The token minted when the temporary write happened.
    /// - Returns: `true` when restoration is safe.
    public func shouldRestore(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?
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

    /// Reports whether the pasteboard's current contents are the flow's own
    /// temporary write recorded by `token` (as opposed to a user change).
    /// - Parameters:
    ///   - pasteboard: The pasteboard to inspect.
    ///   - token: The token minted when the temporary write happened.
    /// - Returns: `true` when the current contents are the flow's temporary
    ///   write.
    public func isCurrentTemporaryWrite(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?
    ) -> Bool {
        shouldRestore(pasteboard: pasteboard, token: token)
    }
}
