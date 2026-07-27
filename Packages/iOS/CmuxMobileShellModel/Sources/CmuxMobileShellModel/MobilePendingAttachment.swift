public import Foundation

/// A picked image held in the composer as a pending attachment, sent to the
/// terminal agent on the next composer submit (iMessage-style: pick now, send
/// with the message).
///
/// Value type so the store logic (add/remove/clear, per-terminal keying) is
/// host-testable without UIKit. The bytes are already encoded the same way the
/// clipboard paste path encodes them (PNG, or JPEG when over the size cap); the
/// composer view builds the thumbnail from ``data`` at render time.
public struct MobilePendingAttachment: Identifiable, Equatable, Sendable {
    /// Stable identity so the chip row can diff and the remove action can target
    /// one attachment without relying on byte equality.
    public let id: UUID
    /// The encoded image bytes (PNG/JPEG), ready to hand to
    /// `submitTerminalPasteImage(_:format:)` as-is.
    public let data: Data
    /// A lowercase file-extension hint (e.g. `"png"`/`"jpg"`) for the Mac side,
    /// matching the clipboard paste path's format argument.
    public let format: String

    /// Creates a pending attachment.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - data: The encoded image bytes.
    ///   - format: A lowercase format hint (`"png"`/`"jpg"`).
    public init(id: UUID = UUID(), data: Data, format: String) {
        self.id = id
        self.data = data
        self.format = format
    }
}
