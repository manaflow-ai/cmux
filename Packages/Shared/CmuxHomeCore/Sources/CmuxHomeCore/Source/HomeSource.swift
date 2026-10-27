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
    /// The owner's current summary and newest messages of one conversation,
    /// pushed after a resubscribe or a gap the owner detected. Applied like
    /// a fetched `snapshot(of:tail:)` page; a conversation that is not open
    /// takes only the summary.
    case conversationPage(ConversationPage)
    /// An owner's transport came back while the merged connection stayed
    /// online (a renewed lease, a socket live again after a disconnect, a
    /// reply after a failed one). The client resends its unconfirmed
    /// intents with their keys and refetches stale streams, as on reconnect.
    case ownerRecovered
    /// The owner will never apply these intents: the account that made
    /// them signed out or another account signed in. The client drops them
    /// in every state (failed sends too) and never resends them, so no
    /// intent goes out under an identity other than the one that made it.
    case intentsRevoked(Set<IdempotencyKey>)
    /// Ephemeral, never stored.
    case typing(ConversationID, ParticipantID, on: Bool)
    /// An agent's running reply (ephemeral, never stored): Home grows it in
    /// the agent's bubble until the reply is posted.
    case draft(HomeDraftUpdate)
    /// A Chief's live run frame (`chief-live-v1`, ephemeral, never stored):
    /// the reply's text so far and the run's "working on" line.
    case live(HomeLiveEvent)
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

    /// `history` with the owner's stats of the thread roots in the page
    /// (default: none, Model/Thread.swift).
    func historyPage(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> HistoryPage

    /// The root and up to `limit` replies after `afterSeq` (ascending) of one
    /// thread, with the owner's stats of the whole thread (default: a
    /// bounded history scan, Model/Thread.swift).
    func thread(of conversation: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) async throws -> ThreadPage

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
    /// bounded multipart pieces and a final commit before returning.
    /// A video with `ref.poster` declares it in the intent and PUTs the poster
    /// to the answer's `poster_upload` before the video's PUT or commit (the
    /// owner answers 409 `attachment.poster_missing` until then). An image
    /// with `ref.preview` does the same with its preview (intent field
    /// `preview {sha256, byte_count, mime_type}`, url variant `preview`).
    /// Returns the stored ref; its `hash` equals `file.ref.hash`.
    func upload(_ file: AttachmentUpload) async throws -> AttachmentRef

    /// A local file URL holding the variant's bytes. `location` names the
    /// conversation and, when known, the message part that references the
    /// hash (the owner mints download URLs per part). Idempotent (the same
    /// ref and variant return the same file) and cancel-safe (a cancelled
    /// fetch never leaves a partial file behind). A source without a
    /// thumbnail service downsamples the original itself.
    func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL

    /// The conversation's transcript left the screen: the store shows it
    /// nowhere now. A source that subscribed it for the transcript may end
    /// that subscription; the inbox entry stays as its owner lists it.
    /// The store calls it again for a conversation whose transcript closed
    /// while a read of it ran (the read may have set up again what the
    /// first close found nothing of), so a repeated close must be harmless.
    func close(_ conversation: ConversationID)

    /// Whether the owner of `conversation` takes `link_preview` parts. A
    /// sender sends plain text to an owner that does not (an older daemon).
    func acceptsLinkPreviews(in conversation: ConversationID) async -> Bool

    /// Asks the owner of `conversation` for its live run snapshot (`run.live`),
    /// which arrives as a `.live(.snapshot)` event: on open and after a missed frame.
    func requestLive(of conversation: ConversationID) async

    /// The talk steps of a running run as its rows hold them (id, text), for reply
    /// segments the owner's live buffer already freed (a mid-run join). nil: no read.
    func liveRunRows(of conversation: ConversationID, run: String, author: ParticipantID) async -> [HomeLiveRunSnapshot.Step]?

    /// The owner's answer for a message permalink (`conversation-link-resolve`): its seq, thread root and
    /// the path from that root down to it. nil: this owner has no resolver (the message is looked up in pages).
    func resolveLink(conversation: ConversationID, message: MessageID) async throws -> HomeLinkTarget?
}

extension HomeSource {
    public func resolveLink(conversation: ConversationID, message: MessageID) async throws -> HomeLinkTarget? { nil }
    /// Sources that keep no per-transcript state ignore it.
    public func close(_ conversation: ConversationID) {}

    /// Default: an owner without live frames.
    public func requestLive(of conversation: ConversationID) async {}

    /// Default: an owner without run reads.
    public func liveRunRows(of conversation: ConversationID, run: String, author: ParticipantID) async -> [HomeLiveRunSnapshot.Step]? {
        nil
    }

    /// Default: no link preview parts (send plain text).
    public func acceptsLinkPreviews(in conversation: ConversationID) async -> Bool { false }

    /// Default for sources without blob storage.
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        throw HomeRejection.invalid("attachments unsupported")
    }

    /// Default for sources without blob storage.
    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        throw HomeRejection.invalid("attachments unsupported")
    }
}
