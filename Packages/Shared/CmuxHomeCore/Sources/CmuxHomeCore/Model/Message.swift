public import Foundation

/// One content part of a message. Mirrors the conversation owner's `Part`.
public enum MessagePart: Hashable, Sendable, Codable {
    /// Plain text; `mentions` are UTF-16 ranges that name a participant.
    case text(String, mentions: [Mention] = [])
    /// A reference to an agent session the Chief started (acpmux session).
    case work(WorkRef)
    /// A question an agent asks a human; answered with `approval.decide`.
    case approval(ApprovalRef)
    /// A file or image, stored by content hash (bytes go to blob storage first).
    case attachment(AttachmentRef)
    /// A link with its preview (fetched by the owner, never by the client).
    case linkPreview(LinkPreview)
    /// A shared location.
    case location(LocationRef)

    public var plainText: String {
        switch self {
        case .text(let text, _): text
        case .work(let work): work.preview ?? work.title
        case .approval(let approval): approval.prompt
        case .attachment(let file): file.name
        case .linkPreview(let link): link.title ?? link.url
        case .location(let place): place.label ?? "\(place.latitude), \(place.longitude)"
        }
    }
}

public struct Mention: Hashable, Sendable, Codable {
    public var start: Int
    public var length: Int
    public var participant: ParticipantID

    public init(start: Int, length: Int, participant: ParticipantID) {
        self.start = start
        self.length = length
        self.participant = participant
    }
}

public struct WorkRef: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable { case running, waiting, done, failed }
    public var session: String
    public var host: String?
    public var title: String
    public var status: Status
    public var preview: String?

    public init(session: String, host: String? = nil, title: String, status: Status, preview: String? = nil) {
        self.session = session
        self.host = host
        self.title = title
        self.status = status
        self.preview = preview
    }
}

public struct ApprovalRef: Hashable, Sendable, Codable {
    public var request: String
    public var prompt: String
    public var options: [String]
    public var decided: String?

    public init(request: String, prompt: String, options: [String], decided: String? = nil) {
        self.request = request
        self.prompt = prompt
        self.options = options
        self.decided = decided
    }
}

public struct AttachmentRef: Hashable, Sendable, Codable {
    /// Content hash of the bytes (the blob key).
    public var hash: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    /// Display pixel size for images and video, for layout before the bytes
    /// arrive: EXIF orientation is applied for images and the track's
    /// preferred transform for video (a portrait phone photo is taller than wide).
    public var width: Int?
    public var height: Int?
    /// Playback length of video and audio, in milliseconds.
    public var durationMs: Int?
    /// The poster frame of a video: a separate blob in the same part (one
    /// part per attachment). Fetch it with `AttachmentVariant.poster`.
    public var poster: AttachmentPoster?
    /// An image's preview (JPEG, at most 1024 px and 512 KB): readers load
    /// it first with `AttachmentVariant.preview` and the original on tap.
    /// Best effort: a small image, or one whose preview failed, has none.
    public var preview: AttachmentDerivedImage?

    /// Content hash of the poster blob, when the part has one.
    public var posterHash: String? { poster?.hash }

    public init(hash: String, name: String, mimeType: String, byteCount: Int, width: Int? = nil, height: Int? = nil,
                durationMs: Int? = nil, poster: AttachmentPoster? = nil, preview: AttachmentDerivedImage? = nil) {
        self.hash = hash
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.poster = poster
        self.preview = preview
    }

    /// The owner's attachment part fields (snake_case); absent optionals are
    /// omitted. This is the ref's own body only: `MessagePart` uses
    /// synthesized Codable, which wraps it as `{"attachment":{"_0":{...}}}`,
    /// not the owner's `{"type":"attachment",...}`. A cloud source maps parts
    /// to and from the owner's shape itself.
    enum CodingKeys: String, CodingKey {
        case hash, name, width, height, poster, preview
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case durationMs = "duration_ms"
    }

    /// Keys an earlier client build encoded before the wire keys.
    private enum LegacyCodingKeys: String, CodingKey {
        case mimeType, byteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? legacy.decode(String.self, forKey: .mimeType)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
            ?? legacy.decode(Int.self, forKey: .byteCount)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        poster = try container.decodeIfPresent(AttachmentPoster.self, forKey: .poster)
        preview = try container.decodeIfPresent(AttachmentDerivedImage.self, forKey: .preview)
    }
}

/// A small image stored with an attachment's record, equal to what the
/// owner recorded (home-messaging.md 10.1): a video's poster frame, or an
/// image's preview. Wire shape `{hash, mime_type, byte_count}`. It has no
/// record or part of its own and the owner chooses its storage key, so a
/// client fetches it only as `AttachmentVariant.poster` or `.preview` of
/// its part.
public typealias AttachmentPoster = AttachmentDerivedImage

/// See `AttachmentPoster`.
public struct AttachmentDerivedImage: Hashable, Sendable, Codable {
    /// SHA-256 of the image bytes.
    public var hash: String
    /// `image/jpeg` or `image/webp` (`HomeAttachmentPolicy.posterTypes`).
    public var mimeType: String
    public var byteCount: Int

    public init(hash: String, mimeType: String, byteCount: Int) {
        self.hash = hash
        self.mimeType = mimeType
        self.byteCount = byteCount
    }

    enum CodingKeys: String, CodingKey {
        case hash
        case mimeType = "mime_type"
        case byteCount = "byte_count"
    }
}

public struct LinkPreview: Hashable, Sendable, Codable {
    public var url: String
    public var title: String?
    public var summary: String?
    /// Content hash of the preview image, when the owner fetched one.
    public var imageHash: String?

    public init(url: String, title: String? = nil, summary: String? = nil, imageHash: String? = nil) {
        self.url = url
        self.title = title
        self.summary = summary
        self.imageHash = imageHash
    }
}

public struct LocationRef: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var label: String?

    public init(latitude: Double, longitude: Double, label: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
    }
}

/// One part of one message (the target of a reply).
public struct PartRef: Hashable, Sendable, Codable {
    public var message: MessageID
    public var partIndex: Int

    public init(message: MessageID, partIndex: Int = 0) {
        self.message = message
        self.partIndex = partIndex
    }
}

public struct Reaction: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case tapback(Tapback)
        case emoji(String)
    }

    public enum Tapback: String, Hashable, Sendable, Codable, CaseIterable {
        case love, like, dislike, laugh, emphasize, question
    }

    public var author: ParticipantID
    public var partIndex: Int
    public var kind: Kind

    public init(author: ParticipantID, partIndex: Int, kind: Kind) {
        self.author = author
        self.partIndex = partIndex
        self.kind = kind
    }
}

/// A committed message. Only the owner creates these; clients render them
/// from the mirror.
public struct Message: Hashable, Sendable, Codable, Identifiable {
    public let id: MessageID
    public let conversation: ConversationID
    public let seq: Seq
    public let clientMessageID: IdempotencyKey
    public let author: ParticipantID
    public var parts: [MessagePart]
    public let createdAt: Date
    public var editedAt: Date?
    public var retractedAt: Date?
    public var reactions: [Reaction]
    /// The message part this one answers (an inline reply).
    public var replyTo: PartRef?
    /// The first message of the thread this message belongs to.
    public var threadRoot: MessageID?

    public init(
        id: MessageID,
        conversation: ConversationID,
        seq: Seq,
        clientMessageID: IdempotencyKey,
        author: ParticipantID,
        parts: [MessagePart],
        createdAt: Date,
        editedAt: Date? = nil,
        retractedAt: Date? = nil,
        reactions: [Reaction] = [],
        replyTo: PartRef? = nil,
        threadRoot: MessageID? = nil
    ) {
        self.id = id
        self.conversation = conversation
        self.seq = seq
        self.clientMessageID = clientMessageID
        self.author = author
        self.parts = parts
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.retractedAt = retractedAt
        self.reactions = reactions
        self.replyTo = replyTo
        self.threadRoot = threadRoot
    }

    public var plainText: String { parts.map(\.plainText).joined(separator: "\n") }
    public var isRetracted: Bool { retractedAt != nil }
}
