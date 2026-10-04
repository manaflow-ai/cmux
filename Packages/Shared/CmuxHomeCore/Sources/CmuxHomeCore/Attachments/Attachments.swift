public import Foundation

/// The local files behind one attachment on this client: the bytes in the
/// blob cache, and the poster frame for video. Renderers show these while
/// the bytes upload and after the echo, so a sent photo never reloads.
public struct LocalAttachmentFiles: Hashable, Sendable {
    public var fileURL: URL
    public var posterURL: URL?

    public init(fileURL: URL, posterURL: URL? = nil) {
        self.fileURL = fileURL
        self.posterURL = posterURL
    }
}

/// An attachment prepared for sending: its ref (hash, display size,
/// duration, poster hash) and its files in the client blob cache.
public struct LocalAttachment: Hashable, Sendable {
    public var ref: AttachmentRef
    public var fileURL: URL
    public var posterURL: URL?

    public init(ref: AttachmentRef, fileURL: URL, posterURL: URL? = nil) {
        self.ref = ref
        self.fileURL = fileURL
        self.posterURL = posterURL
    }

    public var files: LocalAttachmentFiles { LocalAttachmentFiles(fileURL: fileURL, posterURL: posterURL) }
}

/// One upload request to a `HomeSource`.
public struct AttachmentUpload: Sendable {
    public var conversation: ConversationID
    /// The bytes; their SHA-256 is `ref.hash`.
    public var fileURL: URL
    public var ref: AttachmentRef
    /// The poster frame for video; its SHA-256 is `ref.posterHash`.
    public var posterURL: URL?
    /// Fraction uploaded, 0...1, from any thread.
    public var progress: @Sendable (Double) -> Void

    public init(conversation: ConversationID, fileURL: URL, ref: AttachmentRef, posterURL: URL? = nil,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.conversation = conversation
        self.fileURL = fileURL
        self.ref = ref
        self.posterURL = posterURL
        self.progress = progress
    }
}

/// Which bytes of an attachment a renderer wants.
public enum AttachmentVariant: Hashable, Sendable {
    /// The uploaded bytes.
    case original
    /// An image (JPEG) whose longer side is at most `maxPixel`; the poster
    /// frame for video.
    case thumbnail(maxPixel: Int)
}
