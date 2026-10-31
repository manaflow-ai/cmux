import CmuxAgentQuestion
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
        var preview: AttachmentDerivedImage?
    }

    /// The attachment records, by content hash.
    private var blobs: [String: BlobRecord] = [:]
    /// Poster and preview bytes by hash. Neither has a record of its own:
    /// each belongs to its attachment's record.
    private var posterBlobs: [String: Data] = [:]
    private var uploadsPaused = false
    private var pausedUploads: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Paused uploads whose task was cancelled before they registered.
    private var cancelledPauses: Set<UUID> = []
    private var failingUploads: [String: (times: Int, error: HomeRejection)] = [:]
    /// Submits of these keys fail before the ledger, `times` more times.
    private var failingSubmits: [IdempotencyKey: (times: Int, error: HomeRejection)] = [:]
    /// The next submit of each key commits, then loses its answer and holds
    /// back its events; the value is how many later submits fail after it.
    private var losingAnswers: [IdempotencyKey: Int] = [:]
    /// True while a commit whose answer is lost runs: its events wait in
    /// `withheldEvents` until `releaseWithheldEvents`.
    private var holdingEvents = false
    private var withheldEvents: [HomeEvent] = []
    /// True while `holdSubmits` holds every submit before the owner looks at it.
    private var holdingSubmits = false
    private var heldSubmits: [CheckedContinuation<Void, Never>] = []
    /// The progress callback of every upload call, in call order (tests
    /// replay late callbacks with `replayProgress`).
    private var progressCallbacks: [@Sendable (Double) -> Void] = []
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
        if holdingSubmits { await withCheckedContinuation { heldSubmits.append($0) } }
        guard online else { throw HomeRejection.ownerUnreachable }
        if let failing = failingSubmits[intent.key] {
            failingSubmits[intent.key] = failing.times > 1 ? (failing.times - 1, failing.error) : nil
            throw failing.error
        }
        if let failingAfter = losingAnswers.removeValue(forKey: intent.key), ledger[intent.key] == nil {
            // Committed, but neither the answer nor the echo arrives.
            holdingEvents = true
            let outcome = Result { try apply(intent) }
            holdingEvents = false
            if case .success(let result) = outcome { ledger[intent.key] = (intent.op, .success(result)) }
            if failingAfter > 0 { failingSubmits[intent.key] = (failingAfter, .indeterminate) }
            throw HomeRejection.indeterminate
        }
        if let decided = ledger[intent.key] {
            guard decided.op == intent.op else { throw HomeRejection.invalid("idempotency_conflict") }
            var replay = try decided.outcome.get()
            replay.replayed = true
            return replay
        }
        if case .sendMessage(_, let parts, _, _) = intent.op {
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
        if case .sendMessage(let conversation, let parts, let threadRoot, let parent) = intent.op {
            scheduleReplies(in: conversation, parts: parts, answering: parent ?? threadRoot)
        }
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
    /// The mock owner checks `link_preview` parts like the real owners.
    public func acceptsLinkPreviews(in conversation: ConversationID) async -> Bool { true }

    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        uploadCalls.append(file.ref.hash)
        progressCallbacks.append(file.progress)
        if options.latency > .zero { try await clock.sleep(for: options.latency) }
        guard online else { throw HomeRejection.ownerUnreachable }
        file.progress(0.25)
        file.progress(0.5)
        if uploadsPaused { try await pause() }
        // The connection may have dropped while the bytes were in flight.
        guard online else { throw HomeRejection.ownerUnreachable }
        if let failing = failingUploads[file.ref.hash] {
            failingUploads[file.ref.hash] = failing.times > 1 ? (failing.times - 1, failing.error) : nil
            throw failing.error
        }
        // The owner's upload intent rules: an allowed type spelled as on
        // the allow list, positive dimensions, a duration within 24 hours.
        guard HomeAttachmentPolicy.allowedTypes[file.ref.mimeType.lowercased()] != nil else {
            throw HomeRejection.invalid("type_refused")
        }
        let dimensions = [file.ref.width, file.ref.height].compactMap { $0 }
        guard dimensions.allSatisfy(HomeAttachmentPolicy.dimensionRange.contains),
              file.ref.durationMs.map(HomeAttachmentPolicy.durationRange.contains) ?? true else {
            throw HomeRejection.invalid("validation_invalid")
        }
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
        // The same for an image's preview.
        if let meta = file.ref.preview, posterBlobs[meta.hash] == nil {
            guard file.ref.mimeType.hasPrefix("image/") else { throw HomeRejection.invalid("preview_refused") }
            guard let previewURL = file.previewURL else { throw HomeRejection.invalid("preview_missing") }
            let preview = try Data(contentsOf: previewURL)
            guard HomeAttachmentPolicy.posterTypes.contains(meta.mimeType), preview.count <= HomeAttachmentPolicy.previewMaxBytes,
                  preview.count == meta.byteCount, AttachmentMedia.sha256(of: preview) == meta.hash else {
                throw HomeRejection.invalid("hash_mismatch")
            }
            posterBlobs[meta.hash] = preview
        }
        let data = try Data(contentsOf: file.fileURL)
        guard AttachmentMedia.sha256(of: data) == file.ref.hash else { throw HomeRejection.invalid("hash_mismatch") }
        let record = BlobRecord(data: data, mimeType: file.ref.mimeType.lowercased(), poster: file.ref.poster,
                                preview: file.ref.preview)
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
        ref.preview = record.preview
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
        case .preview:
            guard ref.preview != nil, let meta = blob.preview, let preview = posterBlobs[meta.hash] else {
                throw HomeRejection.invalid("no_preview")
            }
            let ext = UTType(mimeType: meta.mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
            let target = fetchDirectory.appendingPathComponent("\(ref.hash)-preview\(ext)")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            try Task.checkCancellation()
            try preview.write(to: target, options: .atomic)
            return target
        }
    }

    /// Waits until uploads resume; a cancelled task stops waiting at once
    /// and throws `CancellationError`.
    private func pause() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledPauses.remove(id) != nil {
                    continuation.resume()
                } else {
                    pausedUploads[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPause(id) }
        }
        try Task.checkCancellation()
    }

    private func cancelPause(_ id: UUID) {
        if let continuation = pausedUploads.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledPauses.insert(id)
        }
    }

    // MARK: Test and demo controls

    /// While paused, uploads stop at 0.5 progress until resumed (previews of
    /// the uploading state, and tests).
    public func setUploadsPaused(_ paused: Bool) {
        uploadsPaused = paused
        guard !paused else { return }
        let waiting = pausedUploads.values
        pausedUploads.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// The next `times` uploads of this hash fail with `error`.
    public func failNextUpload(hash: String, with error: HomeRejection = .invalid("attachment_upload_failed"), times: Int = 1) {
        failingUploads[hash] = times > 0 ? (times, error) : nil
    }

    /// Calls the progress callback of upload call `index` again (a late
    /// callback that arrives after its upload ended).
    public func replayProgress(ofCall index: Int, _ fraction: Double) {
        guard progressCallbacks.indices.contains(index) else { return }
        progressCallbacks[index](fraction)
    }

    /// The next `times` submits of `key` fail with `error` before the owner
    /// looks at them (an answer lost in flight, by default); 0 clears it.
    public func failNextSubmits(of key: IdempotencyKey, times: Int, with error: HomeRejection = .indeterminate) {
        failingSubmits[key] = times > 0 ? (times, error) : nil
    }

    /// The next submit of `key` commits, then throws `indeterminate` and
    /// holds back its events (the answer and the echo are lost); the
    /// `failingAfter` submits after it fail before the ledger, like
    /// `failNextSubmits`. `releaseWithheldEvents` delivers the echo.
    public func commitThenLoseAnswer(of key: IdempotencyKey, failingAfter: Int = 0) {
        losingAnswers[key] = failingAfter
    }

    /// Publishes the events a lost answer held back, in order.
    public func releaseWithheldEvents() {
        let events = withheldEvents
        withheldEvents.removeAll()
        for event in events { publish(event) }
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

    /// Holds every later submit before the owner looks at it, until `releaseSubmits` (a send
    /// stays pending in the client while other traffic commits).
    public func holdSubmits() { holdingSubmits = true }

    /// Lets the held submits go, in the order they came, and stops holding.
    public func releaseSubmits() {
        holdingSubmits = false
        let waiting = heldSubmits
        heldSubmits.removeAll()
        for submit in waiting { submit.resume() }
    }

    /// Submits waiting for `releaseSubmits` now.
    public var heldSubmitCount: Int { heldSubmits.count }

    /// Posts `text` as `author` under `key` (a Chief's reply carries its turn key) and returns its seq.
    @discardableResult
    public func post(_ text: String, from author: ParticipantID, in conversation: ConversationID, key: IdempotencyKey) -> Seq? {
        post([.text(text)], from: author, in: conversation, key: key)
    }

    /// Posts `parts` as `author` under `key`, in `threadRoot`'s thread when one is given (a Chief's
    /// done marker answers the message it closes), and returns its seq.
    @discardableResult
    public func post(_ parts: [MessagePart], from author: ParticipantID, in conversation: ConversationID, key: IdempotencyKey,
                     threadRoot: MessageID? = nil) -> Seq? {
        guard (try? commitMessage(in: conversation, author: author, parts: parts, key: key, threadRoot: threadRoot)) != nil else { return nil }
        return conversations[conversation]?.lastSeq
    }

    /// Adds `kind` from `author` to part `partIndex` of message `messageID`, as the owner
    /// commits another participant's `reaction.add` (a Chief's `react` tool, a group member's
    /// tapback): the message's update reaches every subscriber. False when the message is unknown.
    @discardableResult
    public func react(_ kind: Reaction.Kind, to messageID: MessageID, from author: ParticipantID,
                      in conversation: ConversationID, partIndex: Int = 0) -> Bool {
        guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == messageID }),
              var summary = conversations[conversation] else { return false }
        let reaction = Reaction(author: author, partIndex: partIndex, kind: kind)
        if !list[index].reactions.contains(reaction) { list[index].reactions.append(reaction) }
        stored[conversation] = list
        summary.rev += 1
        if summary.lastMessage?.id == messageID { summary.lastMessage = list[index] }
        conversations[conversation] = summary
        publish(.message(list[index], rev: summary.rev))
        return true
    }

    /// `reader` reads `conversation` up to its newest message, as the owner moves another
    /// member's read cursor ("Read" under my message); nothing when it already has.
    ///
    /// - Parameters:
    ///   - reader: The member whose read cursor moves (the Chief, a teammate).
    ///   - conversation: The conversation they read.
    public func markRead(by reader: ParticipantID, in conversation: ConversationID) {
        guard var summary = conversations[conversation], (summary.readCursors[reader] ?? 0) < summary.lastSeq else { return }
        summary.readCursors[reader] = summary.lastSeq
        summary.readCursorTimes[reader] = Date()
        summary.rev += 1
        conversations[conversation] = summary
        publish(.conversationChanged(summary, stream: .conversation(conversation), rev: summary.rev))
    }

    /// Posts a message as someone else (incoming traffic for demos).
    public func receive(_ text: String, from author: ParticipantID, in conversation: ConversationID) {
        _ = try? commitMessage(in: conversation, author: author, parts: [.text(text)], key: .make())
    }

    /// Publishes one draft item of an agent's running reply, as an owner streams a Chief turn (demos and the
    /// DEBUG Home fixture's width sweep). Nothing is stored: the reply posts only through ``receive(_:from:in:)``.
    public func streamDraft(_ update: HomeDraftUpdate) {
        publish(.draft(update))
    }

    /// Publishes one live run frame (``HomeLiveEvent``), as an owner sends a running Chief's
    /// "working on" line (the DEBUG Home fixture's status-line captures). Nothing is stored.
    ///
    /// - Parameter event: The frame, for example an `.activity` frame with the step running now.
    public func streamLive(_ event: HomeLiveEvent) {
        publish(.live(event))
    }

    // MARK: Owner logic

    private func apply(_ intent: HomeIntent) throws -> HomeOpResult {
        switch intent.op {
        case .sendMessage(let conversation, let parts, let threadRoot, let parent):
            let text = parts.map(\.plainText).joined()
            guard !text.isEmpty, text.utf8.count <= 65_536 else { throw HomeRejection.invalid("invalid_parts") }
            // The owner's checkAttachments: a recorded hash, and the part's
            // type, size and claimed poster equal to the record.
            for case .attachment(let ref) in parts {
                guard let record = blobs[ref.hash] else { throw HomeRejection.invalid("unknown_attachment") }
                guard record.mimeType == ref.mimeType, record.data.count == ref.byteCount,
                      ref.poster == nil || ref.poster == record.poster,
                      ref.preview == nil || ref.preview == record.preview else {
                    throw HomeRejection.invalid("attachment_mismatch")
                }
            }
            // A link preview's picture: a recorded image of the same type and size.
            for case .linkPreview(let link) in parts {
                guard let image = link.image else { continue }
                guard let record = blobs[image.hash] else { throw HomeRejection.invalid("unknown_attachment") }
                guard record.mimeType == image.mimeType, record.data.count == image.byteCount else {
                    throw HomeRejection.invalid("attachment_mismatch")
                }
            }
            // The root, and a parent of the thread at any depth, must be stored messages of the conversation.
            if let threadRoot, [threadRoot, parent ?? threadRoot].contains(where: { id in stored[conversation]?.contains { $0.id == id } != true }) {
                throw HomeRejection.invalid("unknown_reply_target")
            }
            // The owner's rule (conversation-tree-v1): a parent is the root or a reply in the root's thread.
            if let threadRoot, let parent, parent != threadRoot,
               stored[conversation]?.first(where: { $0.id == parent })?.threadRoot != threadRoot {
                throw HomeRejection.invalid("invalid_thread_root")
            }
            let rev = try commitMessage(in: conversation, author: me.id, parts: parts, key: intent.key, threadRoot: threadRoot, parent: parent)
            return HomeOpResult(rev: rev, conversation: conversation)
        case .editMessage(let messageID, let conversation, let parts):
            return try updateOwnMessage(messageID, in: conversation) {
                $0.parts = parts
                $0.editedAt = Date()
            }
        case .retractMessage(let messageID, let conversation):
            return try updateOwnMessage(messageID, in: conversation) {
                $0.parts = []
                $0.retractedAt = Date()
            }
        case .removeReaction(let messageID, let conversation, let kind, let partIndex):
            guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == messageID }),
                  var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_message") }
            list[index].reactions.removeAll { $0 == Reaction(author: me.id, partIndex: partIndex, kind: kind) }
            stored[conversation] = list
            summary.rev += 1
            conversations[conversation] = summary
            publish(.message(list[index], rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
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
        case .createGroup(let title, let ids, let invites):
            let participants = [me] + ids.compactMap { people[$0] } + invites.map { personFor($0).0 }
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
        case .openDirect(let peer):
            guard let person = people[peer], peer != me.id else { throw HomeRejection.invalid("not_reachable") }
            let id = existingDirect(with: [me, person]) ?? createConversation(title: "", participants: [me, person])
            return HomeOpResult(rev: inboxRev, conversation: id)
        case .invite(let contact):
            // An invite changes no inbox entry, so the current revision settles it.
            let (_, receipt) = personFor(contact)
            return HomeOpResult(rev: inboxRev, invite: receipt ?? InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: true))
        case .updateThread(let conversation, let root, let title, let status, let owner):
            guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == root }),
                  var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_message") }
            guard list[index].threadRoot == nil else { throw HomeRejection.invalid("invalid_thread_root") }
            var thread = list[index].thread ?? ThreadInfo()
            if let title { thread.title = title.isEmpty ? nil : title }
            if let owner { thread.owner = owner.isEmpty ? nil : ParticipantID(owner) }
            if let status { (thread.resolvedAtSeq, thread.resolvedBy) = status == .resolved ? (summary.lastSeq, me.id) : (nil, nil) }
            list[index].thread = thread == ThreadInfo() ? nil : thread
            stored[conversation] = list
            summary.rev += 1
            conversations[conversation] = summary
            publish(.message(list[index], rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
        case .setChiefReplies(let conversation, let policy):
            guard conversations[conversation] != nil else { throw HomeRejection.invalid("unknown_conversation") }
            guard conversations[conversation]?.kind(me: me.id) == .group else { throw HomeRejection.invalid("kind_forbids") }
            return try updateHead(conversation) { $0.chiefReplies = policy }
        case .renameConversation(let conversation, let title):
            guard conversations[conversation]?.kind(me: me.id) == .group else { throw HomeRejection.invalid("kind_forbids") }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 200 else { throw HomeRejection.invalid("invalid_title") }
            return try updateHead(conversation) { $0.title = trimmed }
        case .addParticipants(let conversation, let ids):
            guard conversations[conversation]?.kind(me: me.id) == .group else { throw HomeRejection.invalid("kind_forbids") }
            let added = try ids.map { id -> Participant in
                guard let person = people[id], person.membership == .active else { throw HomeRejection.invalid("not_reachable") }
                return person
            }
            let current = Set(conversations[conversation]?.participants.map(\.id) ?? [])
            let joining = added.filter { !current.contains($0.id) }
            guard current.count + joining.count <= 64 else { throw HomeRejection.invalid("too_many_participants") }
            return try updateHead(conversation) { $0.participants.append(contentsOf: joining) }
        case .removeParticipant(let conversation, let participant):
            guard let summary = conversations[conversation], summary.kind(me: me.id) == .group else {
                throw HomeRejection.invalid("kind_forbids")
            }
            guard summary.participants.contains(where: { $0.id == participant }) else { throw HomeRejection.invalid("not_participant") }
            guard participant == me.id else {
                return try updateHead(conversation) { $0.participants.removeAll { $0.id == participant } }
            }
            // I left: the conversation goes from my inbox (the owner keeps it for the others).
            conversations[conversation] = nil
            stored[conversation] = nil
            inboxRev += 1
            publish(.conversationRemoved(conversation, inboxRev: inboxRev))
            return HomeOpResult(rev: inboxRev)
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
        case .answerQuestion(let messageID, let conversation, let partIndex, let answer):
            guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == messageID }),
                  var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_message") }
            guard list[index].parts.indices.contains(partIndex), case .question(let question) = list[index].parts[partIndex] else {
                throw HomeRejection.invalid("invalid_part_index")
            }
            let respondent = AgentQuestionAnswer.Respondent(participant: me.id.rawValue, displayName: me.displayName)
            do {
                let answered = try question.answering(answer, respondent: respondent, atMs: Int64(Date().timeIntervalSince1970 * 1000))
                list[index].parts[partIndex] = .question(answered)
            } catch AgentQuestionAnswer.Problem.notPending {
                throw HomeRejection.invalid("question_closed")
            } catch {
                throw HomeRejection.invalid("invalid_answer")
            }
            stored[conversation] = list
            summary.rev += 1
            conversations[conversation] = summary
            publish(.message(list[index], rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
        }
    }

    /// A change to a conversation's head (title, members): its own stream's next revision.
    private func updateHead(_ conversation: ConversationID, _ change: (inout ConversationSummary) -> Void) throws -> HomeOpResult {
        guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        change(&summary)
        summary.rev += 1
        conversations[conversation] = summary
        publish(.conversationChanged(summary, stream: .conversation(conversation), rev: summary.rev))
        return HomeOpResult(rev: summary.rev, conversation: conversation)
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
    /// The owner's edit and retract: only the author changes a message, and a retracted one stays retracted.
    private func updateOwnMessage(_ messageID: MessageID, in conversation: ConversationID,
                                  _ change: (inout Message) -> Void) throws -> HomeOpResult {
        guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == messageID }),
              var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_message") }
        guard list[index].author == me.id else { throw HomeRejection.notAuthorized }
        guard list[index].retractedAt == nil else { throw HomeRejection.invalid("message_retracted") }
        change(&list[index])
        stored[conversation] = list
        summary.rev += 1
        if summary.lastMessage?.id == messageID { summary.lastMessage = list[index] }
        conversations[conversation] = summary
        publish(.message(list[index], rev: summary.rev))
        return HomeOpResult(rev: summary.rev)
    }

    private func commitMessage(in conversation: ConversationID, author: ParticipantID, parts: [MessagePart], key: IdempotencyKey,
                               threadRoot: MessageID? = nil, parent: MessageID? = nil) throws -> Revision {
        guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        guard summary.participants.contains(where: { $0.id == author }) else { throw HomeRejection.notAuthorized }
        let message = Message(id: MessageID("msg_\(mintID())"), conversation: conversation, seq: summary.lastSeq + 1,
                              clientMessageID: key, author: author, parts: parts, createdAt: Date(),
                              replyTo: threadRoot.map { PartRef(message: parent ?? $0) }, threadRoot: threadRoot)
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
        let summary = ConversationSummary(id: id, title: title, participants: participants, createdAt: now, updatedAt: now,
                                          declaredKind: participants.count > 2 ? .group : nil)
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

    /// The Chiefs the owner's rule wakes for my message (``ChiefReplyPolicy``) answer it, one after another.
    private func scheduleReplies(in conversation: ConversationID, parts: [MessagePart], answering: MessageID?) {
        guard let summary = conversations[conversation] else { return }
        var mentioned: Set<ParticipantID> = []
        for case .text(_, let mentions) in parts { mentioned.formUnion(mentions.map(\.participant)) }
        let repliedTo = answering.flatMap { id in stored[conversation]?.first { $0.id == id }?.author }
        let policy = summary.chiefReplies ?? .default
        let ids = policy.responders(among: summary.participants, author: me.id, mentioned: mentioned, repliedTo: repliedTo)
        let responders = ids.compactMap { id in summary.participants.first { $0.id == id } }
        guard !responders.isEmpty else { return }
        let delay = options.replyDelay
        let clock = self.clock
        Task {
            for responder in responders {
                if delay > .zero { try? await clock.sleep(for: delay) }
                self.typing(responder.id, in: conversation, on: true)
                if delay > .zero { try? await clock.sleep(for: delay) }
                self.reply(as: responder, in: conversation)
            }
        }
    }

    /// Sets a participant's activity for demos without starting a timed reply.
    public func typing(_ who: ParticipantID, in conversation: ConversationID, on: Bool) {
        publish(.typing(conversation, who, on: on))
    }

    /// Who has `conversation` open, the whole set, as an owner's presence frame (fixtures and
    /// captures: `debug.home.drive` `presence`); an empty set is nobody.
    public func showPresence(_ viewing: Set<ParticipantID>, in conversation: ConversationID) {
        publish(.presence(conversation, viewing: viewing))
    }

    /// `who` starts or stops typing in `conversation`, as an owner's typing frame (fixtures).
    public func showTyping(_ who: ParticipantID, in conversation: ConversationID, on: Bool) {
        typing(who, in: conversation, on: on)
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
        if holdingEvents {
            withheldEvents.append(event)
            return
        }
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func mintID() -> String {
        defer { nextID += 1 }
        return String(format: "mock%06d", nextID)
    }
}
