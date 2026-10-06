import Foundation

/// `{sha256, byte_count, mime_type}` of a poster or preview in an upload `begin`.
public struct ConversationDerivedImageDeclaration: Encodable, Sendable, Hashable {
    public var sha256: String
    public var byteCount: Int
    public var mimeType: String

    public init(sha256: String, byteCount: Int, mimeType: String) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mimeType = mimeType
    }

    enum CodingKeys: String, CodingKey {
        case sha256
        case byteCount = "byte_count"
        case mimeType = "mime_type"
    }
}

/// `conversation-attachment-upload` (`local-attachments-v1`): one step of a
/// chunked upload, chosen by `op` (`begin`, `chunk`, `commit`, `cancel`).
/// Use `ConversationClient.uploadAttachment`, which runs the whole upload.
public struct ConversationAttachmentUploadRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// `begin`: nil when the conversation already holds the hash (`stored`).
        public var upload: String?
        /// `begin`: the pieces whose bytes to send, in order.
        public var needs: [ConversationAttachmentVariant]?
        /// `begin` (already held) and `commit`.
        public var stored: StoredConversationAttachment?
        /// `chunk`: bytes received so far for the piece.
        public var received: Int?
    }

    public static let command = "conversation-attachment-upload"
    public var op: String
    public var conversation: String?
    public var sha256: String?
    public var byteCount: Int?
    public var mimeType: String?
    public var name: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var poster: ConversationDerivedImageDeclaration?
    public var preview: ConversationDerivedImageDeclaration?
    public var upload: String?
    public var piece: ConversationAttachmentVariant?
    public var offset: Int?
    public var data: String?

    enum CodingKeys: String, CodingKey {
        case op, conversation, sha256, name, width, height, poster, preview, upload, piece, offset, data
        case byteCount = "byte_count"
        case mimeType = "mime_type"
        case durationMs = "duration_ms"
    }

    init(op: String) {
        self.op = op
    }

    /// Declares the file a later `chunk` sequence sends.
    public static func begin(conversation: String, attachment: ConversationAttachment) -> Self {
        var request = Self(op: "begin")
        request.conversation = conversation
        request.sha256 = attachment.hash
        request.byteCount = attachment.byteCount
        request.mimeType = attachment.mimeType
        request.name = attachment.name
        request.width = attachment.width
        request.height = attachment.height
        request.durationMs = attachment.durationMs
        request.poster = attachment.poster.map { ConversationDerivedImageDeclaration(sha256: $0.hash, byteCount: $0.byteCount, mimeType: $0.mimeType) }
        request.preview = attachment.preview.map { ConversationDerivedImageDeclaration(sha256: $0.hash, byteCount: $0.byteCount, mimeType: $0.mimeType) }
        return request
    }

    public static func chunk(upload: String, piece: ConversationAttachmentVariant, offset: Int, bytes: Data) -> Self {
        var request = Self(op: "chunk")
        request.upload = upload
        request.piece = piece
        request.offset = offset
        request.data = bytes.base64EncodedString()
        return request
    }

    public static func commit(upload: String) -> Self {
        var request = Self(op: "commit")
        request.upload = upload
        return request
    }

    public static func cancel(upload: String) -> Self {
        var request = Self(op: "cancel")
        request.upload = upload
        return request
    }
}

/// `conversation-attachment-read` (`local-attachments-v1`): up to `length`
/// bytes of one variant of a part's hash from `offset`.
public struct ConversationAttachmentReadRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The hash of the variant read (a preview's own hash).
        public var hash: String
        public var mimeType: String
        public var byteCount: Int
        public var offset: Int
        /// Base64.
        public var data: String
        public var eof: Bool

        enum CodingKeys: String, CodingKey {
            case hash, offset, data, eof
            case mimeType = "mime_type"
            case byteCount = "byte_count"
        }
    }

    public static let command = "conversation-attachment-read"
    public var conversation: String
    public var hash: String
    public var variant: ConversationAttachmentVariant
    public var offset: Int
    public var length: Int

    public init(conversation: String, hash: String, variant: ConversationAttachmentVariant, offset: Int, length: Int) {
        self.conversation = conversation
        self.hash = hash
        self.variant = variant
        self.offset = offset
        self.length = length
    }
}
