public import Foundation
import UniformTypeIdentifiers

/// An in-memory owner for Home, used until the messaging backend lands and in
/// tests, previews and demos. It behaves like a real owner: it assigns seqs and
/// revisions, dedupes idempotency keys, publishes events after each commit,
/// refuses ops while offline, and lets Chiefs answer.
public actor MockHomeSource: HomeSource {
    public struct Options: Sendable {
        /// Messages in the Chief conversation (generated on demand, never all held).
        public var chiefHistory: Int
        /// Simulated owner latency for ops.
        public var latency: Duration
        /// Delay before a Chief starts typing and before it answers.
        public var replyDelay: Duration
        public var startsOnline: Bool

        public init(chiefHistory: Int = 2_000, latency: Duration = .milliseconds(120),
                    replyDelay: Duration = .milliseconds(900), startsOnline: Bool = true) {
            self.chiefHistory = chiefHistory
            self.latency = latency
            self.replyDelay = replyDelay
            self.startsOnline = startsOnline
        }

        /// No delays: for tests.
        public static let immediate = Options(chiefHistory: 300, latency: .zero, replyDelay: .zero)
    }

    private let options: Options
    private let clock: any Clock<Duration>
    private var online: Bool
    private var inboxRev: Revision = 1
    private var conversations: [ConversationID: ConversationSummary] = [:]
    /// Materialized messages; the generated Chief history before `generatedUpTo` is computed on read.
    private var stored: [ConversationID: [Message]] = [:]
    private var generated: [ConversationID: Seq] = [:]
    /// Decided keys, like the owner's request ledger: a result or a refusal
    /// that is not retryable. The same key answers the same again; with
    /// another op it is refused `idempotency_conflict`.
    private var ledger: [IdempotencyKey: (op: HomeOp, outcome: Result<HomeOpResult, HomeRejection>)] = [:]
    /// Hashes whose record the next submits drop first (an unreferenced
    /// upload swept after 24 hours, an expired slot), with the count left.
    private var forgetOnSubmit: [String: Int] = [:]
    private var subscribers: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
    private var people: [ParticipantID: Participant] = [:]
    private var members: [ContactAddress: ParticipantID] = [:]
    private var nextID = 1
    /// One attachment record: the first upload of a hash wins, so a later
    /// upload of the same bytes gets this record's mime type and poster back.
    private struct BlobRecord {
        var data: Data
        var mimeType: String
        var poster: AttachmentPoster?
    }

    /// The attachment records, by content hash.
    private var blobs: [String: BlobRecord] = [:]
    /// Poster bytes by poster hash. A poster has no record of its own: it
    /// belongs to its video's record.
    private var posterBlobs: [String: Data] = [:]
    private var uploadsPaused = false
    private var pausedUploads: [CheckedContinuation<Void, Never>] = []
    private var failingUploads: Set<String> = []
    /// Every upload call, by hash, in call order (for tests).
    public private(set) var uploadCalls: [String] = []
    /// The location of every fetch, in call order (for tests).
    public private(set) var fetchLocations: [AttachmentLocation] = []
    /// Where `fetch` writes files (one directory per source instance).
    private let fetchDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-home-mock-blobs", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    public let me: Participant
    public let chief: Participant
    private let epoch: Date

    public init(options: Options = Options(), clock: any Clock<Duration> = ContinuousClock(), now: Date = Date()) {
        self.options = options
        self.clock = clock
        self.online = options.startsOnline
        self.epoch = now
        let seed = MockHomeSeed.make(now: now, chiefHistory: options.chiefHistory)
        self.me = seed.me
        self.chief = seed.chief
        for summary in seed.conversations { conversations[summary.id] = summary }
        stored = seed.messages
        generated = seed.generated
        for person in seed.people { people[person.id] = person }
        members = seed.members
    }

    // MARK: HomeSource

    public func events() -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        if online {
            continuation.yield(.connection(.online))
            continuation.yield(.inbox(inboxSnapshot()))
        } else {
            continuation.yield(.connection(.offline(since: Date())))
        }
        return stream
    }

    public func inbox() throws -> InboxSnapshot {
        guard online else { throw HomeRejection.ownerUnreachable }
        return inboxSnapshot()
    }

    public func snapshot(of conversation: ConversationID, tail: Int) throws -> ConversationPage {
        guard online else { throw HomeRejection.ownerUnreachable }
        guard let summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        let last = summary.lastSeq
        let first = last >= Seq(tail) ? last - Seq(tail) + 1 : 1
        return ConversationPage(conversation: summary, messages: messages(in: conversation, from: first, through: last))
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) throws -> [Message] {
        guard online else { throw HomeRejection.ownerUnreachable }
        guard beforeSeq > 1 else { return [] }
        let last = beforeSeq - 1
        let first = last >= Seq(limit) ? last - Seq(limit) + 1 : 1
        return messages(in: conversation, from: first, through: last)
    }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if options.latency > .zero { try? await clock.sleep(for: options.latency) }
        guard online else { throw HomeRejection.ownerUnreachable }
        if let decided = ledger[intent.key] {
            guard decided.op == intent.op else { throw HomeRejection.invalid("idempotency_conflict") }
            var replay = try decided.outcome.get()
            replay.replayed = true
            return replay
        }
        if case .sendMessage(_, let parts) = intent.op {
            for case .attachment(let ref) in parts {
                guard let left = forgetOnSubmit[ref.hash] else { continue }
                blobs[ref.hash] = nil
                forgetOnSubmit[ref.hash] = left > 1 ? left - 1 : nil
            }
        }
        let result: HomeOpResult
        do {
            result = try apply(intent)
        } catch let rejection as HomeRejection where !rejection.isRetryable {
            ledger[intent.key] = (intent.op, .failure(rejection))
            throw rejection
        }
        ledger[intent.key] = (intent.op, .success(result))
        if case .sendMessage(let conversation, _) = intent.op { scheduleReplies(in: conversation) }
        return result
    }

    public func search(_ query: String, limit: Int) throws -> [HomeSearchHit] {
        guard online else { throw HomeRejection.ownerUnreachable }
        let needle = query.lowercased()
        var hits: [HomeSearchHit] = []
        let ordered = conversations.values.sorted { $0.updatedAt > $1.updatedAt }
        for summary in ordered {
            let last = summary.lastSeq
            let first = last > 2_000 ? last - 1_999 : 1
            for message in messages(in: summary.id, from: first, through: last).reversed() {
                let text = message.plainText
                guard let range = text.lowercased().range(of: needle) else { continue }
                let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
                hits.append(HomeSearchHit(conversation: summary.id, message: message, highlights: [start..<(start + length)]))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    public func resolve(_ contact: ContactAddress) throws -> ContactResolution {
        guard online else { throw HomeRejection.ownerUnreachable }
        if let id = members[contact], let person = people[id] { return .member(person) }
        return .invitable(contact)
    }

    /// Stores the bytes under their hash (verified) and reports progress in
    /// four steps: 0.25 and 0.5, a pause while `setUploadsPaused(true)`, then
    /// 0.75 and 1. Like the owner, the first upload of a hash wins: a hash
    /// already recorded answers `exists` with the recorded mime type, byte
    /// count and poster (or no poster), whatever this upload declared.
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        uploadCalls.append(file.ref.hash)
        if options.latency > .zero { try? await clock.sleep(for: options.latency) }
        guard online else { throw HomeRejection.ownerUnreachable }
        file.progress(0.25)
        file.progress(0.5)
        if uploadsPaused { await withCheckedContinuation { pausedUploads.append($0) } }
        if failingUploads.remove(file.ref.hash) != nil { throw HomeRejection.ownerUnreachable }
        if let record = blobs[file.ref.hash] {
            file.progress(1)
            return Self.stored(file.ref, record)
        }
        // The owner's order: the declared poster lands before the video.
        if let meta = file.ref.poster, posterBlobs[meta.hash] == nil {
            guard file.ref.mimeType.hasPrefix("video/") else { throw HomeRejection.invalid("poster_refused") }
            guard let posterURL = file.posterURL else { throw HomeRejection.invalid("poster_missing") }
            let poster = try Data(contentsOf: posterURL)
            guard HomeAttachmentPolicy.posterTypes.contains(meta.mimeType), poster.count <= HomeAttachmentPolicy.posterMaxBytes,
                  poster.count == meta.byteCount, AttachmentMedia.sha256(of: poster) == meta.hash else {
                throw HomeRejection.invalid("hash_mismatch")
            }
            posterBlobs[meta.hash] = poster
        }
        let data = try Data(contentsOf: file.fileURL)
        guard AttachmentMedia.sha256(of: data) == file.ref.hash else { throw HomeRejection.invalid("hash_mismatch") }
        let record = BlobRecord(data: data, mimeType: file.ref.mimeType.lowercased(), poster: file.ref.poster)
        blobs[file.ref.hash] = record
        file.progress(0.75)
        file.progress(1)
        return Self.stored(file.ref, record)
    }

    /// The ref an upload answers: the declared one with the record's mime
    /// type, byte count and poster.
    private static func stored(_ declared: AttachmentRef, _ record: BlobRecord) -> AttachmentRef {
        var ref = declared
        ref.mimeType = record.mimeType
        ref.byteCount = record.data.count
        ref.poster = record.poster
        return ref
    }

    /// Writes the blob (or a JPEG thumbnail of it or of the video's poster, or
    /// the poster itself)
    /// to a file named by hash and variant. Atomic writes, so a cancelled
    /// fetch leaves nothing partial; a second fetch returns the same file.
    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        fetchLocations.append(location)
        guard let blob = blobs[ref.hash] else { throw HomeRejection.invalid("unknown_blob") }
        try FileManager.default.createDirectory(at: fetchDirectory, withIntermediateDirectories: true)
        switch variant {
        case .original:
            let ext = UTType(mimeType: blob.mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
            let target = fetchDirectory.appendingPathComponent("\(ref.hash)-original\(ext)")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            try Task.checkCancellation()
            try blob.data.write(to: target, options: .atomic)
            return target
        case .thumbnail(let maxPixel):
            let target = fetchDirectory.appendingPathComponent("\(ref.hash)-thumb-\(maxPixel).jpg")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            // An image's own bytes, or a video's recorded poster.
            let imageVariant: AttachmentVariant
            if blob.mimeType.hasPrefix("image/") {
                imageVariant = .original
            } else if blob.poster != nil {
                imageVariant = .poster
            } else {
                throw HomeRejection.invalid("no_thumbnail")
            }
            let original = try await fetch(ref, at: location, variant: imageVariant)
            let data = try AttachmentMedia.thumbnailJPEG(of: original, maxPixel: maxPixel)
            try Task.checkCancellation()
            try data.write(to: target, options: .atomic)
            return target
        case .poster:
            // A part without a poster has none to fetch; otherwise the
            // record's poster (the owner mints the URL from the record).
            guard ref.poster != nil, let meta = blob.poster, let poster = posterBlobs[meta.hash] else { throw HomeRejection.invalid("no_poster") }
            let ext = UTType(mimeType: meta.mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
            let target = fetchDirectory.appendingPathComponent("\(ref.hash)-poster\(ext)")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            try Task.checkCancellation()
            try poster.write(to: target, options: .atomic)
            return target
        }
    }

    // MARK: Test and demo controls

    /// While paused, uploads stop at 0.5 progress until resumed (previews of
    /// the uploading state, and tests).
    public func setUploadsPaused(_ paused: Bool) {
        uploadsPaused = paused
        guard !paused else { return }
        let waiting = pausedUploads
        pausedUploads.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// The next upload of this hash fails as unreachable (once).
    public func failNextUpload(hash: String) {
        failingUploads.insert(hash)
    }

    /// The next `times` submits that reference `hash` drop its record first,
    /// so the owner answers `unknown_attachment`.
    public func forgetBlobBeforeNextSubmits(_ hash: String, times: Int = 1) {
        forgetOnSubmit[hash] = times
    }

    /// True once the blob store holds this hash.
    public func hasBlob(_ hash: String) -> Bool { blobs[hash] != nil }

    /// Simulates losing or regaining the owners.
    public func setOnline(_ value: Bool) {
        guard value != online else { return }
        online = value
        if value {
            publish(.connection(.online))
            publish(.inbox(inboxSnapshot()))
        } else {
            publish(.connection(.offline(since: Date())))
        }
    }

    /// Posts a message as someone else (incoming traffic for demos).
    public func receive(_ text: String, from author: ParticipantID, in conversation: ConversationID) {
        _ = try? commitMessage(in: conversation, author: author, parts: [.text(text)], key: .make())
    }

    // MARK: Owner logic

    private func apply(_ intent: HomeIntent) throws -> HomeOpResult {
        switch intent.op {
        case .sendMessage(let conversation, let parts):
            let text = parts.map(\.plainText).joined()
            guard !text.isEmpty, text.utf8.count <= 65_536 else { throw HomeRejection.invalid("invalid_parts") }
            // The owner's checkAttachments: a recorded hash, and the part's
            // type, size and claimed poster equal to the record.
            for case .attachment(let ref) in parts {
                guard let record = blobs[ref.hash] else { throw HomeRejection.invalid("unknown_attachment") }
                guard record.mimeType == ref.mimeType, record.data.count == ref.byteCount,
                      ref.poster == nil || ref.poster == record.poster else {
                    throw HomeRejection.invalid("attachment_mismatch")
                }
            }
            let rev = try commitMessage(in: conversation, author: me.id, parts: parts, key: intent.key)
            return HomeOpResult(rev: rev, conversation: conversation)
        case .setReadCursor(let conversation, let seq):
            guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
            let current = summary.readCursors[me.id] ?? 0
            guard seq <= summary.lastSeq else { throw HomeRejection.invalid("cursor_beyond_end") }
            guard seq > current else { return HomeOpResult(rev: summary.rev) }
            summary.readCursors[me.id] = seq
            summary.readCursorTimes[me.id] = Date()
            summary.rev += 1
            conversations[conversation] = summary
            publish(.conversationChanged(summary, stream: .conversation(conversation), rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
        case .setPinned(let conversation, let rank):
            return try updateInbox(conversation) { $0.pinRank = rank }
        case .setMuted(let conversation, let muted):
            return try updateInbox(conversation) { $0.muted = muted }
        case .createChief(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 60 else { throw HomeRejection.invalid("invalid_name") }
            let agent = Participant(id: ParticipantID("agent_\(mintID())"), kind: .agent, displayName: trimmed,
                                    agentClass: .chief, ownerUser: me.id)
            people[agent.id] = agent
            let id = createConversation(title: "", participants: [me, agent])
            _ = try? commitMessage(in: id, author: agent.id, parts: [.text(MockHomeSeed.chiefGreeting(trimmed))], key: .make())
            return HomeOpResult(rev: inboxRev, conversation: id)
        case .createGroup(let title, let ids):
            let participants = [me] + ids.compactMap { people[$0] }
            guard participants.count >= 3 else { throw HomeRejection.invalid("group_needs_three") }
            let id = createConversation(title: title, participants: participants)
            return HomeOpResult(rev: inboxRev, conversation: id)
        case .startConversation(let contacts, let firstMessage):
            guard !contacts.isEmpty else { throw HomeRejection.invalid("no_recipients") }
            var participants = [me]
            var receipt: InviteReceipt?
            for contact in contacts {
                let (person, invite) = personFor(contact)
                participants.append(person)
                receipt = receipt ?? invite
            }
            let id = existingDirect(with: participants) ?? createConversation(title: "", participants: participants)
            if !firstMessage.isEmpty {
                _ = try? commitMessage(in: id, author: me.id, parts: firstMessage, key: intent.key)
            }
            return HomeOpResult(rev: inboxRev, conversation: id, invite: receipt)
        case .invite(let contact):
            // An invite changes no inbox entry, so the current revision settles it.
            let (_, receipt) = personFor(contact)
            return HomeOpResult(rev: inboxRev, invite: receipt ?? InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: true))
        case .setTyping(let conversation, let on):
            // Ephemeral: broadcast, never stored, no revision.
            guard let summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
            publish(.typing(conversation, me.id, on: on))
            return HomeOpResult(rev: summary.rev)
        case .addReaction(let messageID, let conversation, let kind, let partIndex):
            guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == messageID }),
                  var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_message") }
            let reaction = Reaction(author: me.id, partIndex: partIndex, kind: kind)
            if !list[index].reactions.contains(reaction) { list[index].reactions.append(reaction) }
            stored[conversation] = list
            summary.rev += 1
            conversations[conversation] = summary
            publish(.message(list[index], rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
        }
    }

    private func updateInbox(_ conversation: ConversationID, _ change: (inout ConversationSummary) -> Void) throws -> HomeOpResult {
        guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        change(&summary)
        conversations[conversation] = summary
        inboxRev += 1
        publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev))
        return HomeOpResult(rev: inboxRev)
    }

    @discardableResult
    private func commitMessage(in conversation: ConversationID, author: ParticipantID, parts: [MessagePart], key: IdempotencyKey) throws -> Revision {
        guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        guard summary.participants.contains(where: { $0.id == author }) else { throw HomeRejection.notAuthorized }
        let message = Message(id: MessageID("msg_\(mintID())"), conversation: conversation, seq: summary.lastSeq + 1,
                              clientMessageID: key, author: author, parts: parts, createdAt: Date())
        stored[conversation, default: []].append(message)
        summary.lastSeq = message.seq
        summary.lastMessage = message
        summary.updatedAt = message.createdAt
        summary.rev += 1
        if author == me.id { summary.readCursors[me.id] = message.seq }
        conversations[conversation] = summary
        publish(.message(message, rev: summary.rev))
        return summary.rev
    }

    private func createConversation(title: String, participants: [Participant]) -> ConversationID {
        let id = ConversationID("conv_\(mintID())")
        let now = Date()
        let summary = ConversationSummary(id: id, title: title, participants: participants, createdAt: now, updatedAt: now)
        conversations[id] = summary
        inboxRev += 1
        publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev))
        return id
    }

    private func existingDirect(with participants: [Participant]) -> ConversationID? {
        guard participants.count == 2 else { return nil }
        let wanted = Set(participants.map(\.id))
        return conversations.values.first { Set($0.participants.map(\.id)) == wanted && $0.title.isEmpty }?.id
    }

    private func personFor(_ contact: ContactAddress) -> (Participant, InviteReceipt?) {
        if let id = members[contact], let person = people[id] { return (person, nil) }
        let person = Participant(id: ParticipantID("user_inv_\(mintID())"), kind: .human, displayName: contact.description,
                                 membership: .invited, invitedContact: contact.description)
        people[person.id] = person
        members[contact] = person.id
        return (person, InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: false))
    }

    private func scheduleReplies(in conversation: ConversationID) {
        guard let summary = conversations[conversation] else { return }
        let chiefs = summary.participants.filter(\.isChief)
        // In groups a Chief answers only when mentioned (multi-party rule); the mock answers with the first Chief.
        guard let responder = chiefs.first else { return }
        let delay = options.replyDelay
        let clock = self.clock
        Task {
            if delay > .zero { try? await clock.sleep(for: delay) }
            self.typing(responder.id, in: conversation, on: true)
            if delay > .zero { try? await clock.sleep(for: delay) }
            self.reply(as: responder, in: conversation)
        }
    }

    private func typing(_ who: ParticipantID, in conversation: ConversationID, on: Bool) {
        publish(.typing(conversation, who, on: on))
    }

    private func reply(as responder: Participant, in conversation: ConversationID) {
        publish(.typing(conversation, responder.id, on: false))
        let count = stored[conversation]?.count ?? 0
        _ = try? commitMessage(in: conversation, author: responder.id,
                               parts: [.text(MockHomeSeed.reply(index: count))], key: .make())
    }

    private func messages(in conversation: ConversationID, from first: Seq, through last: Seq) -> [Message] {
        guard first <= last, let summary = conversations[conversation] else { return [] }
        let generatedUpTo = generated[conversation] ?? 0
        var result: [Message] = []
        result.reserveCapacity(Int(last - first + 1))
        if first <= generatedUpTo {
            for seq in first...min(last, generatedUpTo) {
                result.append(MockHomeSeed.generatedMessage(seq: seq, total: generatedUpTo, in: summary, epoch: epoch))
            }
        }
        if last > generatedUpTo {
            let lower = max(first, generatedUpTo + 1)
            result.append(contentsOf: (stored[conversation] ?? []).filter { $0.seq >= lower && $0.seq <= last })
        }
        return result
    }

    private func inboxSnapshot() -> InboxSnapshot {
        InboxSnapshot(me: me, conversations: Array(conversations.values), rev: inboxRev)
    }

    private func publish(_ event: HomeEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func mintID() -> String {
        defer { nextID += 1 }
        return String(format: "mock%06d", nextID)
    }
}
