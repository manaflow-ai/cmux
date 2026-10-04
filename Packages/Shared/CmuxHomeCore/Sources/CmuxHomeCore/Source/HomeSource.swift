public import Foundation

/// Connection state of the Home owners as the client sees it.
public enum HomeConnection: Hashable, Sendable {
    case connecting
    case online
    /// Offline: every new op is refused locally; cached state is read-only.
    case offline(since: Date)
}

/// An owner's ordered event log. Ordering holds within one stream, never across.
public enum HomeStream: Hashable, Sendable {
    /// The user's account inbox (conversation list, pins, mutes, unread).
    case inbox
    /// One conversation (messages, reactions, read cursors, participants).
    case conversation(ConversationID)
}

/// Events an owner publishes, in owner order per stream. `rev` is the
/// stream's revision after the change; a jump of more than one is a gap and
/// the client refetches that stream.
public enum HomeEvent: Hashable, Sendable {
    case connection(HomeConnection)
    /// Full account inbox (first connect, reconnect, or after a gap).
    case inbox(InboxSnapshot)
    /// A conversation's summary changed (title, participants, pin, cursors, last message).
    case conversationChanged(ConversationSummary, stream: HomeStream, rev: Revision)
    /// A conversation left the inbox (archived or the user left).
    case conversationRemoved(ConversationID, inboxRev: Revision)
    /// A message was committed (new) or updated (edit, retract, reaction).
    case message(Message, rev: Revision)
    /// Ephemeral, never stored.
    case typing(ConversationID, ParticipantID, on: Bool)
}

/// One search hit over Home messages.
public struct HomeSearchHit: Hashable, Sendable, Identifiable {
    public var conversation: ConversationID
    public var message: Message
    /// UTF-16 ranges in `message.plainText` that matched.
    public var highlights: [Range<Int>]

    public init(conversation: ConversationID, message: Message, highlights: [Range<Int>]) {
        self.conversation = conversation
        self.message = message
        self.highlights = highlights
    }

    public var id: MessageID { message.id }
}

/// Resolution of a typed email or phone number before an invite.
public enum ContactResolution: Hashable, Sendable {
    /// The address belongs to a cmux user; the DM opens directly.
    case member(Participant)
    /// No account yet; sending invites them.
    case invitable(ContactAddress)
}

/// The single seam between the Home UI and every backend: a mock today, the
/// local conversation owner on a Mac, and the cloud owners (conversation and
/// account inbox) once the Home messaging backend lands. Implementations own
/// transport and identity; the client owns only its mirror and intent log.
public protocol HomeSource: Sendable {
    /// Owner events. A source yields `.connection` first, then `.inbox`.
    /// One stream per call; ends when the source shuts down.
    func events() async -> AsyncStream<HomeEvent>

    /// The account inbox, for a refetch after a gap.
    func inbox() async throws -> InboxSnapshot

    /// The newest `tail` messages of a conversation, plus its summary.
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage

    /// Up to `limit` messages before `beforeSeq`, ascending.
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message]

    /// Sends an intent to its owner. Throws `HomeRejection`.
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult

    /// Searches Home messages only (never terminals, files or the web).
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit]

    /// Looks up whether an address already belongs to a cmux user.
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution

    /// Uploads one prepared attachment's bytes (and its poster, when set) to
    /// the conversation's blob storage under `file.ref.hash`. Idempotent by
    /// hash: a blob the conversation already holds succeeds without sending
    /// the bytes again. Files over `HomeAttachmentPolicy.streamMaxBytes` use
    /// the owner's presigned PUT and its commit call before returning; a 412
    /// on a retried presigned PUT means the first attempt landed, so commit.
    /// A video with `ref.poster` declares it in the intent and PUTs the poster
    /// to the answer's `poster_upload` before the video's PUT or commit (the
    /// owner answers 409 `attachment.poster_missing` until then).
    /// Returns the stored ref; its `hash` equals `file.ref.hash`.
    func upload(_ file: AttachmentUpload) async throws -> AttachmentRef

    /// A local file URL holding the variant's bytes. `location` names the
    /// conversation and, when known, the message part that references the
    /// hash (the owner mints download URLs per part). Idempotent (the same
    /// ref and variant return the same file) and cancel-safe (a cancelled
    /// fetch never leaves a partial file behind). A source without a
    /// thumbnail service downsamples the original itself.
    func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL
}

extension HomeSource {
    /// Default for sources without blob storage.
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        throw HomeRejection.invalid("attachments unsupported")
    }

    /// Default for sources without blob storage.
    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        throw HomeRejection.invalid("attachments unsupported")
    }
}
