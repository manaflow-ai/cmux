public import CmuxMobileSupport
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
    /// Stable host-side operation retained while this draft item is retried.
    public let operationID: UUID
    /// The encoded image bytes (PNG/JPEG), ready to hand to
    /// `submitTerminalPasteImage(_:format:)` as-is.
    public let localFileURL: URL
    /// Exact staged byte count.
    public let byteCount: Int
    /// Original user-visible filename.
    public let fileName: String
    /// Image or document treatment.
    public let kind: MobileStagedAttachment.Kind
    /// A lowercase file-extension hint (e.g. `"png"`/`"jpg"`) for the Mac side,
    /// matching the clipboard paste path's format argument.
    public let format: String

    /// Compatibility byte access for focused legacy tests and callers.
    public var data: Data {
        (try? Data(contentsOf: localFileURL, options: .mappedIfSafe)) ?? Data()
    }

    /// Creates a pending attachment.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - data: The encoded image bytes.
    ///   - format: A lowercase format hint (`"png"`/`"jpg"`).
    public init(id: UUID = UUID(), operationID: UUID = UUID(), data: Data, format: String) {
        self.id = id
        self.operationID = operationID
        self.format = format
        let fileName = "attachment-\(id.uuidString).\(format)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url, options: .atomic)
        self.localFileURL = url
        self.byteCount = data.count
        self.fileName = fileName
        self.kind = .image
    }

    /// Creates a terminal draft item from a shared exact-byte attachment.
    public init(_ attachment: MobileStagedAttachment) {
        self.id = attachment.id
        self.operationID = UUID()
        self.localFileURL = attachment.localFileURL
        self.byteCount = attachment.byteCount
        self.fileName = attachment.fileName
        self.kind = attachment.kind
        self.format = (attachment.fileName as NSString).pathExtension.lowercased()
    }
}
