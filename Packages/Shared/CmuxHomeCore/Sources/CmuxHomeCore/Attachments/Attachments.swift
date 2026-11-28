public import Foundation

/// The local files behind one attachment on this client: the bytes in the
/// blob cache, and the poster frame for video. Renderers show these while
/// the bytes upload and after the echo, so a sent photo never reloads.
public struct LocalAttachmentFiles: Hashable, Sendable {
    public var fileURL: URL
    public var posterURL: URL?
    /// SHA-256 of the poster file. A part whose poster differs (the owner
    /// kept another device's poster) fetches the poster from the source.
    public var posterHash: String?
    /// An image's preview file and its SHA-256 (same rule as the poster).
    public var previewURL: URL?
    public var previewHash: String?

    public init(fileURL: URL, posterURL: URL? = nil, posterHash: String? = nil, previewURL: URL? = nil,
                previewHash: String? = nil) {
        self.fileURL = fileURL
        self.posterURL = posterURL
        self.posterHash = posterHash
        self.previewURL = previewURL
        self.previewHash = previewHash
    }
}

/// An attachment prepared for sending: its ref (hash, display size,
/// duration, poster hash) and its files in the client blob cache.
public struct LocalAttachment: Hashable, Sendable {
    public var ref: AttachmentRef
    public var fileURL: URL
    public var posterURL: URL?
    /// An image's preview; its SHA-256 is `ref.preview?.hash`.
    public var previewURL: URL?

    public init(ref: AttachmentRef, fileURL: URL, posterURL: URL? = nil, previewURL: URL? = nil) {
        self.ref = ref
        self.fileURL = fileURL
        self.posterURL = posterURL
        self.previewURL = previewURL
    }

    public var files: LocalAttachmentFiles {
        LocalAttachmentFiles(fileURL: fileURL, posterURL: posterURL, posterHash: posterURL == nil ? nil : ref.posterHash,
                             previewURL: previewURL, previewHash: previewURL == nil ? nil : ref.preview?.hash)
    }
}

/// One upload request to a `HomeSource`.
public struct AttachmentUpload: Sendable {
    public var conversation: ConversationID
    /// The bytes; their SHA-256 is `ref.hash`.
    public var fileURL: URL
    public var ref: AttachmentRef
    /// The poster frame for video; its SHA-256 is `ref.posterHash`.
    public var posterURL: URL?
    /// An image's preview; its SHA-256 is `ref.preview?.hash`.
    public var previewURL: URL?
    /// Fraction uploaded, 0...1, from any thread.
    public var progress: @Sendable (Double) -> Void

    public init(conversation: ConversationID, fileURL: URL, ref: AttachmentRef, posterURL: URL? = nil,
                previewURL: URL? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.conversation = conversation
        self.fileURL = fileURL
        self.ref = ref
        self.posterURL = posterURL
        self.previewURL = previewURL
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
    /// A video part's poster frame as stored (`ref.poster`, JPEG or WebP),
    /// not resized: the owner's url request with `variant: "poster"` for the
    /// video part, never a poster key. A part without a poster (the owner's
    /// 404 `attachment.no_poster`) throws `HomeRejection.invalid("no_poster")`;
    /// renderers show a placeholder and never fetch the video in its place.
    case poster
    /// An image part's preview as stored (`ref.preview`, JPEG or WebP, at
    /// most 1024 px and 512 KB): the owner's url request with
    /// `variant: "preview"`. Readers show it first and load `.original` on
    /// tap. A part without one throws `HomeRejection.invalid("no_preview")`;
    /// renderers then use `.thumbnail` or `.original`.
    case preview
}
