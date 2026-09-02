public import AppKit
public import Foundation

/// Materializes pasteboard images into owned temporary files for terminal
/// paste and drag flows.
///
/// Implemented by `TerminalPasteboardService` in `CmuxTerminalServices`. The
/// service tracks every file it writes as "owned" so cleanup paths can safely
/// delete exactly the files cmux created and nothing else.
///
/// Isolation: requirements are synchronous and the conforming service is
/// `Sendable`; callers include upload completion handlers on background
/// queues.
public protocol TerminalImagePasteWriting: AnyObject, Sendable {
    /// Materializes the first decodable pasteboard image into a temporary
    /// file.
    func materializeImageFileURLIfNeeded(
        from pasteboard: NSPasteboard
    ) -> TerminalImageFileMaterialization

    /// Materializes every decodable pasteboard image into temporary files.
    func materializeImageFileURLsIfNeeded(
        from pasteboard: NSPasteboard
    ) -> TerminalImageFileListMaterialization

    /// When the pasteboard has no paste text (or `assumeNoText` is set),
    /// materializes every image and returns the file URLs; empty otherwise.
    func saveImageFileURLsIfNeeded(from pasteboard: NSPasteboard, assumeNoText: Bool) -> [URL]

    /// When the pasteboard has no paste text (or `assumeNoText` is set),
    /// materializes the first image and returns its file URL.
    func saveImageFileURLIfNeeded(from pasteboard: NSPasteboard, assumeNoText: Bool) -> URL?

    /// When the pasteboard has no paste text (or `assumeNoText` is set),
    /// materializes the first image and returns its shell-escaped path.
    func saveClipboardImageIfNeeded(from pasteboard: NSPasteboard, assumeNoText: Bool) -> String?

    /// Writes raw image bytes (e.g. forwarded from a paired mobile client) to
    /// an owned temporary file and returns its shell-escaped path.
    func saveImageData(_ data: Data, fileExtension: String) -> String?

    /// Writes raw image bytes to an owned temporary file and returns its URL.
    func saveImageDataFileURL(_ data: Data, fileExtension: String) -> URL?

    /// Whether the file was materialized by this service and is still owned.
    func isOwnedTemporaryImageFile(_ fileURL: URL) -> Bool

    /// Deletes the given files if (and only if) this service still owns them,
    /// consuming ownership.
    func cleanupTransferredTemporaryImageFiles(_ fileURLs: [URL])

    /// Deletes every temporary image file this service still owns.
    func cleanupAllOwnedTemporaryImageFiles()
}

public extension TerminalImagePasteWriting {
    /// Legacy conformers may not support URL-returning image materialization.
    /// The shell-escaped ``saveImageData(_:fileExtension:)`` requirement
    /// remains available, while callers that need ownership-aware URL cleanup
    /// receive `nil` and can take their existing fallback path.
    func saveImageDataFileURL(_ data: Data, fileExtension: String) -> URL? {
        _ = data
        _ = fileExtension
        return nil
    }
}
