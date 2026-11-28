public import Foundation

/// A picked or pasted item held in the composer as a pending attachment, sent
/// to the terminal agent on the next composer submit (iMessage-style: stage
/// now, send with the message).
///
/// Value type so the store logic (add/remove/clear, per-terminal keying) is
/// host-testable without UIKit. Image bytes are already encoded the way the
/// clipboard paste path encodes them (PNG, or JPEG when over the size cap) and
/// travel through `terminal.paste_image`; file bytes are uploaded to the Mac at
/// send time and land in the message as a shell-quoted absolute path. The
/// composer view builds image thumbnails from ``data`` at render time.
public struct MobilePendingAttachment: Identifiable, Equatable, Sendable {
    /// How the staged bytes reach the Mac on submit.
    public enum Kind: Equatable, Sendable {
        /// An encoded image sent inline through `terminal.paste_image`.
        case image
        /// Arbitrary file bytes uploaded through the chunked task-attachment
        /// verb; the message references the returned Mac path.
        case file
    }

    /// Stable identity so the chip row can diff and the remove action can target
    /// one attachment without relying on byte equality.
    public let id: UUID
    /// Transport selector for the submit path.
    public let kind: Kind
    /// The staged bytes: encoded image bytes (PNG/JPEG) for ``Kind/image``,
    /// raw file bytes for ``Kind/file``.
    public let data: Data
    /// A lowercase file-extension hint (e.g. `"png"`/`"jpg"`, or the file's own
    /// extension), matching the clipboard paste path's format argument.
    public let format: String
    /// The user-visible file name shown on a file chip and sent to the Mac as
    /// the upload's file name. `nil` for images, whose chips render thumbnails.
    public let displayName: String?
    /// A small encoded chip preview, built ONCE at stage time (image
    /// downsample, or a Quick Look thumbnail for files). Carried on the staged
    /// value — not in a view-side cache — so a terminal or workspace switch
    /// that recreates the composer view re-renders the same preview.
    public let thumbnailData: Data?

    /// Creates a pending attachment.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - kind: Transport selector; defaults to ``Kind/image`` to match the
    ///     pre-file callers.
    ///   - data: The staged bytes.
    ///   - format: A lowercase file-extension hint (`"png"`/`"jpg"`/`"pdf"`).
    ///   - displayName: User-visible file name for ``Kind/file`` chips.
    ///   - thumbnailData: Small encoded chip preview, if available.
    public init(
        id: UUID = UUID(),
        kind: Kind = .image,
        data: Data,
        format: String,
        displayName: String? = nil,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.data = data
        self.format = format
        self.displayName = displayName
        self.thumbnailData = thumbnailData
    }
}
