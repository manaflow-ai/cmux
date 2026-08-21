public import Foundation

/// A picked image or file held in the composer as a pending attachment, sent to
/// the terminal agent on the next composer submit (iMessage-style: pick now,
/// send with the message).
///
/// Value type so the store logic (add/remove/clear, per-terminal keying) is
/// host-testable without UIKit. Image bytes are already encoded the same way the
/// clipboard paste path encodes them (PNG, or JPEG when over the size cap) and
/// are delivered through the image paste RPC; file bytes are uploaded to the Mac
/// at send time and land in the message as a shell-quoted path.
public struct MobilePendingAttachment: Identifiable, Equatable, Sendable {
    /// The staged payload's send route: images go through the terminal image
    /// paste RPC, files are uploaded and referenced by Mac path in the text.
    public enum Kind: Equatable, Sendable {
        case image
        case file
    }

    /// Stable identity so the chip row can diff and the remove action can target
    /// one attachment without relying on byte equality.
    public let id: UUID
    /// Whether the staged bytes are an encoded image or a general file.
    public let kind: Kind
    /// The staged bytes: encoded image (PNG/JPEG) for ``Kind/image``, raw file
    /// contents for ``Kind/file``.
    public let data: Data
    /// A lowercase file-extension hint (e.g. `"png"`/`"jpg"`/`"pdf"`), used by
    /// the Mac side to name the delivered file and by previews to type it.
    public let format: String
    /// User-visible name shown on the chip and as the preview title. Derived
    /// from the source's original file name when known.
    public let displayName: String

    /// Creates a pending attachment.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - kind: Image or file; defaults to `.image` (the original send route).
    ///   - data: The staged bytes.
    ///   - format: A lowercase file-extension hint (`"png"`/`"jpg"`/`"pdf"`).
    ///   - displayName: User-visible name; when `nil`, a generic name is derived
    ///     from the format so every chip and preview has a title.
    public init(
        id: UUID = UUID(),
        kind: Kind = .image,
        data: Data,
        format: String,
        displayName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.data = data
        self.format = format
        self.displayName = displayName
            ?? (format.isEmpty ? "attachment" : "attachment.\(format)")
    }
}
