public import Foundation

/// An identity stamp for the temporary file URL the text-box file-paste flow
/// writes onto `NSPasteboard.general`.
///
/// The submission flow writes a temporary file URL to the general pasteboard so
/// the terminal can paste it, then needs to restore the user's original
/// clipboard. This token records what the flow itself wrote (the standardized
/// URL and the pasteboard `changeCount` captured immediately after the write)
/// so ``TextBoxPasteboardRestorationGuard`` can later tell its own write apart
/// from a user clipboard change before restoring.
public struct TextBoxPasteboardRestorationToken: Equatable, Sendable {
    /// The pasteboard `changeCount` captured immediately after the temporary
    /// write.
    public let changeCount: Int

    /// The standardized temporary file URL that was written.
    public let fileURL: URL

    /// Creates a restoration token.
    /// - Parameters:
    ///   - changeCount: The pasteboard `changeCount` captured right after the
    ///     temporary write.
    ///   - fileURL: The standardized temporary file URL that was written.
    public init(changeCount: Int, fileURL: URL) {
        self.changeCount = changeCount
        self.fileURL = fileURL
    }
}
