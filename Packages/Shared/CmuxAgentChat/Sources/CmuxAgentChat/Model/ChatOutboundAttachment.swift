import Foundation

/// An attachment the user is sending with a prompt.
public struct ChatOutboundAttachment: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case image
        case file
    }

    public enum Format: String, Sendable, Equatable {
        case png
        case jpeg
    }

    /// The attachment's explicit storage representation.
    public enum Payload: Sendable, Equatable {
        case inMemoryImage(data: Data, format: Format)
        case stagedFile(url: URL, byteCount: Int)
    }

    /// Stable idempotency identity retained by a pending row across retries.
    public let uploadID: UUID
    /// Stable operation shared by all attachments in one prompt.
    public let operationID: UUID
    public let payload: Payload
    public let fileName: String
    public let kind: Kind
    /// Bounded preview bytes prepared before the attachment reaches a view.
    public let thumbnailData: Data?

    public var localFileURL: URL? {
        guard case let .stagedFile(url, _) = payload else { return nil }
        return url
    }

    public var byteCount: Int {
        switch payload {
        case let .inMemoryImage(data, _): data.count
        case let .stagedFile(_, count): count
        }
    }

    public init(
        data: Data,
        format: Format,
        uploadID: UUID = UUID(),
        operationID: UUID = UUID()
    ) {
        self.uploadID = uploadID
        self.operationID = operationID
        self.payload = .inMemoryImage(data: data, format: format)
        self.fileName = format == .png ? "attachment.png" : "attachment.jpg"
        self.kind = .image
        // Legacy callers have no bounded preview. Retaining `data` here would
        // duplicate the full image payload in view-facing state.
        self.thumbnailData = nil
    }

    public init(
        localFileURL: URL,
        byteCount: Int,
        fileName: String,
        kind: Kind,
        thumbnailData: Data? = nil,
        uploadID: UUID = UUID(),
        operationID: UUID = UUID()
    ) {
        self.uploadID = uploadID
        self.operationID = operationID
        self.payload = .stagedFile(url: localFileURL, byteCount: byteCount)
        self.fileName = fileName
        self.kind = kind
        self.thumbnailData = thumbnailData
    }

    /// Returns the same payload and upload identity under a prompt-wide operation.
    public func withOperationID(_ operationID: UUID) -> Self {
        switch payload {
        case let .inMemoryImage(data, format):
            Self(
                data: data,
                format: format,
                uploadID: uploadID,
                operationID: operationID
            )
        case let .stagedFile(url, byteCount):
            Self(
                localFileURL: url,
                byteCount: byteCount,
                fileName: fileName,
                kind: kind,
                thumbnailData: thumbnailData,
                uploadID: uploadID,
                operationID: operationID
            )
        }
    }
}
