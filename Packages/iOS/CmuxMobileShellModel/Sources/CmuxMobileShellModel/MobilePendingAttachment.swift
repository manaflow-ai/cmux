public import CmuxMobileSupport
public import Foundation

/// A picked file held in the composer until the next explicit terminal send.
///
/// The exact payload stays in an app-owned file while the observable draft holds
/// only metadata and a bounded preview. This keeps large files out of view state.
public struct MobilePendingAttachment: Identifiable, Equatable, Sendable {
    /// Stable identity so the chip row can diff and the remove action can target
    /// one attachment without relying on byte equality.
    public let id: UUID
    /// Stable host-side operation retained while this draft item is retried.
    public let operationID: UUID
    /// App-owned exact payload sent through the chunked attachment route.
    public let localFileURL: URL
    /// Exact staged byte count.
    public let byteCount: Int
    /// Original user-visible filename.
    public let fileName: String
    /// Image or document treatment.
    public let kind: MobileStagedAttachment.Kind
    /// Bounded card preview prepared during staging.
    public let thumbnailData: Data?
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
    public init?(id: UUID = UUID(), operationID: UUID = UUID(), data: Data, format: String) {
        self.init(
            id: id,
            operationID: operationID,
            data: data,
            format: format,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
    }

    init?(
        id: UUID = UUID(),
        operationID: UUID = UUID(),
        data: Data,
        format: String,
        temporaryDirectory: URL
    ) {
        let fileName = "attachment-\(id.uuidString).\(format)"
        let url = temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        self.id = id
        self.operationID = operationID
        self.format = format
        self.localFileURL = url
        self.byteCount = data.count
        self.fileName = fileName
        self.kind = .image
        self.thumbnailData = nil
    }

    /// Creates a terminal draft item from a shared exact-byte attachment.
    public init(_ attachment: MobileStagedAttachment) {
        self.id = attachment.id
        self.operationID = UUID()
        self.localFileURL = attachment.localFileURL
        self.byteCount = attachment.byteCount
        self.fileName = attachment.fileName
        self.kind = attachment.kind
        self.thumbnailData = attachment.thumbnailData
        self.format = (attachment.fileName as NSString).pathExtension.lowercased()
    }
}
