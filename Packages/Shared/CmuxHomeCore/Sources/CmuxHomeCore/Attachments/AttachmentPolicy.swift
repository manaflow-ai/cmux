public import Foundation

/// The owner's attachment rules (home-messaging.md 10.1), checked on the
/// client before any upload so a refused file never leaves the device.
public enum HomeAttachmentPolicy {
    /// Per file, every type (decimal megabytes, like the owner).
    public static let maxBytes = 100_000_000
    /// Up to this size a source streams the bytes through the owner's
    /// Worker; larger files go to a presigned PUT followed by a commit call.
    public static let streamMaxBytes = 32_000_000
    /// At most this many parts per message (attachments plus text).
    public static let maxParts = 16
    /// A video's poster: at most this size, one of `posterTypes`.
    public static let posterMaxBytes = 2_000_000
    public static let posterTypes: Set<String> = ["image/jpeg", "image/webp"]

    /// The allow list: mime type -> inbox preview kind. SVG, HTML and XML are never on it.
    public static let allowedTypes: [String: AttachmentPreview.Kind] = [
        "image/jpeg": .photo, "image/png": .photo, "image/gif": .photo, "image/webp": .photo, "image/heic": .photo,
        "application/pdf": .file, "text/plain": .file, "text/markdown": .file, "text/csv": .file,
        "application/json": .file, "application/zip": .file,
        "video/mp4": .video, "video/quicktime": .video,
        "audio/mp4": .audio, "audio/mpeg": .audio, "audio/aac": .audio, "audio/wav": .audio,
    ]

    /// File extensions of the allowed types, so the mime type does not
    /// depend on the OS's UTType tables.
    static let extensionTypes: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "pdf": "application/pdf", "txt": "text/plain", "text": "text/plain",
        "md": "text/markdown", "markdown": "text/markdown", "csv": "text/csv", "json": "application/json",
        "zip": "application/zip", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "qt": "video/quicktime",
        "m4a": "audio/mp4", "mp3": "audio/mpeg", "aac": "audio/aac", "wav": "audio/wav",
    ]

    /// Other spellings the OS uses for allowed types.
    static let aliases: [String: String] = [
        "image/jpg": "image/jpeg", "audio/x-m4a": "audio/mp4", "audio/m4a": "audio/mp4", "audio/mp3": "audio/mpeg",
        "audio/x-aac": "audio/aac", "audio/vnd.wave": "audio/wav", "audio/wave": "audio/wav", "audio/x-wav": "audio/wav",
        "text/x-markdown": "text/markdown", "application/x-zip-compressed": "application/zip",
    ]

    /// The owner's spelling of a mime type (lowercased, aliases folded).
    public static func canonicalMimeType(_ mimeType: String) -> String {
        let lower = mimeType.lowercased()
        return aliases[lower] ?? lower
    }

    /// Throws `HomeAttachmentError` when the owner would refuse the file.
    public static func check(mimeType: String, byteCount: Int, name: String) throws {
        guard allowedTypes[canonicalMimeType(mimeType)] != nil else {
            throw HomeAttachmentError.typeRefused(mimeType: mimeType, name: name)
        }
        guard byteCount <= maxBytes else { throw HomeAttachmentError.tooLarge(byteCount: byteCount, limit: maxBytes) }
        guard byteCount > 0 else { throw HomeAttachmentError.empty(name: name) }
    }
}

/// Why the client refused an attachment before uploading it.
public enum HomeAttachmentError: Error, Hashable, Sendable {
    /// Not on the allow list (images, PDF, plain text, Markdown, CSV, JSON,
    /// ZIP, MP4, MOV, M4A, MP3, AAC, WAV).
    case typeRefused(mimeType: String, name: String)
    /// Over `HomeAttachmentPolicy.maxBytes`.
    case tooLarge(byteCount: Int, limit: Int)
    /// A file with no bytes.
    case empty(name: String)
    /// More than `HomeAttachmentPolicy.maxParts` parts in one message.
    case tooManyParts(limit: Int)
}

/// The inbox preview of a message's attachments ("2 photos"); clients
/// localize the label. The owner's `preview_attachments {kind, count}`.
public struct AttachmentPreview: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case photo, video, audio, file
    }

    public var kind: Kind
    public var count: Int

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }

    /// The owner's rule: one kind when every attachment has it, else `.file`;
    /// nil without attachments.
    public static func of(_ parts: [MessagePart]) -> AttachmentPreview? {
        let kinds = parts.compactMap { part -> Kind? in
            guard case .attachment(let ref) = part else { return nil }
            return HomeAttachmentPolicy.allowedTypes[HomeAttachmentPolicy.canonicalMimeType(ref.mimeType)] ?? .file
        }
        guard let first = kinds.first else { return nil }
        return AttachmentPreview(kind: kinds.allSatisfy { $0 == first } ? first : .file, count: kinds.count)
    }
}

/// Where an attachment appears: what the owner needs to mint a download
/// URL (the conversation, and the message part that references the hash).
public struct AttachmentLocation: Hashable, Sendable {
    public var conversation: ConversationID
    public var message: MessageID?
    public var partIndex: Int?

    public init(conversation: ConversationID, message: MessageID? = nil, partIndex: Int? = nil) {
        self.conversation = conversation
        self.message = message
        self.partIndex = partIndex
    }
}
