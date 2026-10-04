import Foundation
public import Observation

/// Why `perform` did not return a committed result.
public enum HomeSendState: Error, Hashable, Sendable {
    /// Sent, but the answer was lost; the store resends it with the same key
    /// (the owner applies it once). Do not send it again yourself.
    case pendingResend
}

/// The Home client: the confirmed mirror plus the intent log, fed by one
/// `HomeSource`. The UI reads `rows`, `transcript(for:)` and `connection`,
/// and changes things only through `perform(_:)`.
@MainActor
@Observable
public final class HomeStore {
    /// `.connecting` and `.offline` both refuse new ops (nothing queues).
    public private(set) var connection: HomeConnection = .connecting
    public private(set) var rows: [InboxRow] = []
    /// Increments whenever a transcript's visible items change.
    public private(set) var transcriptVersion: [ConversationID: Int] = [:]
    public private(set) var me: Participant?
    public private(set) var typing: [ConversationID: Set<ParticipantID>] = [:]

    @ObservationIgnored public let source: any HomeSource
    @ObservationIgnored private(set) var mirror = HomeMirror()
    @ObservationIgnored private(set) var log = IntentLog()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resendTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResends: [HomeIntent] = []
    @ObservationIgnored private var refetching: Set<HomeStream> = []
    @ObservationIgnored private var olderLoading: Set<ConversationID> = []
    @ObservationIgnored private var stopped = false
    /// Where prepared attachments live (`<root>/<hash>/data.<ext>`).
    @ObservationIgnored public let blobCacheDirectory: URL
    /// Every attachment this client prepared, by hash (stays after the echo).
    @ObservationIgnored private var localFiles: [String: LocalAttachmentFiles] = [:]
    /// Sends with attachments, from the first upload until the owner
    /// commits them (kept after a refusal, so a retry can upload again).
    @ObservationIgnored private var uploads: [IdempotencyKey: UploadJob] = [:]

    /// Attachment uploads in flight at once, per send.
    public static let uploadConcurrency = 3

    /// Messages fetched when a conversation opens.
    public static let tailSize = 60
    public static let pageSize = 80

    public init(source: any HomeSource, blobCacheDirectory: URL = HomeStore.defaultBlobCacheDirectory) {
        self.source = source
        self.blobCacheDirectory = blobCacheDirectory
    }

    /// `Caches/cmux-home-blobs`.
    public nonisolated static var defaultBlobCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("cmux-home-blobs", isDirectory: true)
    }

    /// Starts consuming owner events. Idempotent.
    public func start() {
        guard eventTask == nil, !stopped else { return }
        let source = self.source
        eventTask = Task { [weak self] in
            let stream = await source.events()
            for await event in stream {
                guard let self, !self.stopped else { return }
                self.handle(event)
            }
        }
    }

    /// Ends this store (sign-out, account switch). Every later op is refused.
    public func stop() {
        stopped = true
        eventTask?.cancel()
        eventTask = nil
        resendTask?.cancel()
        resendTask = nil
        connection = .offline(since: Date())
    }

    // MARK: Reading

    public var isOnline: Bool { connection == .online && !stopped }

    public func summary(_ id: ConversationID) -> ConversationSummary? { mirror.conversations[id] }

    public func transcript(for id: ConversationID) -> [TranscriptItem] {
        guard let me = me?.id else { return [] }
        let items = (mirror.windows[id] ?? TranscriptWindow()).items(pending: log.sends(in: id), me: me)
        guard !localFiles.isEmpty else { return items }
        return items.map(decorated)
    }

    /// Adds local files and upload progress to a row with attachment parts.
    private func decorated(_ item: TranscriptItem) -> TranscriptItem {
        let hashes = item.attachmentHashes
        guard !hashes.isEmpty else { return item }
        var item = item
        for hash in hashes { if let files = localFiles[hash] { item.localAttachments[hash] = files } }
        if item.delivery == .sending, let job = uploads[item.key], job.active {
            item.attachmentProgress = job.progress
        }
        return item
    }

    public func hasOlderMessages(in id: ConversationID) -> Bool {
        guard let window = mirror.windows[id] else { return false }
        return !window.reachedStart
    }

    public func participant(_ id: ParticipantID, in conversation: ConversationID) -> Participant? {
        if id == me?.id { return me }
        return mirror.conversations[conversation]?.participants.first { $0.id == id }
    }

    // MARK: Paging

    /// Loads the newest messages of a conversation the first time it opens.
    /// Events committed while the page loads are buffered and kept.
    public func open(_ id: ConversationID) async {
        guard mirror.windows[id] == nil else { return }
        mirror.beginLoading(id)
        await refetch(.conversation(id))
    }

    public func loadOlder(_ id: ConversationID) async {
        guard let window = mirror.windows[id], !window.reachedStart, let first = window.firstSeq,
              !olderLoading.contains(id) else { return }
        olderLoading.insert(id)
        defer { olderLoading.remove(id) }
        guard let older = try? await source.history(of: id, before: first, limit: Self.pageSize) else { return }
        // The window may have been replaced during the await; a page that no
        // longer joins it is dropped (the next scroll asks again).
        guard mirror.windows[id]?.firstSeq == first else { return }
        if mirror.prepend(older, to: id, reachedStart: older.count < Self.pageSize) { bumpTranscript(id) }
    }

    // MARK: Writing

    /// Sends an intent to its owner. Refused at once unless online (nothing
    /// queues). Throws `HomeRejection` when refused, and
    /// `HomeSendState.pendingResend` when the answer was lost and the store
    /// resends it with the same key.
    @discardableResult
    public func perform(_ op: HomeOp, key: IdempotencyKey = .make()) async throws -> HomeOpResult {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        if case .setTyping = op {
            // Ephemeral: no intent, nothing to settle or resend.
            return try await source.submit(HomeIntent(key: key, op: op))
        }
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        afterLogChange(op)
        return try await submit(intent)
    }

    /// Retries a "Not Delivered" send as a new intent and drops the failed one.
    /// A send whose attachment upload failed never reached the owner: it
    /// keeps its key (and its row) and uploads only the missing attachments.
    /// A send with attachments that the owner refused keeps its row
    /// position under a new key (the owner's ledger keeps the refused one)
    /// and uploads every attachment again first: an upload the owner still
    /// holds answers `exists` without sending the bytes.
    public func retry(_ key: IdempotencyKey) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed = entry.state else { return }
        if let job = uploads[key] {
            var target = key
            if job.reachedOwner {
                target = .make()
                restartUploads(from: key, as: target)
            } else {
                log.setUploading(key, true)
            }
            afterLogChange(entry.intent.op)
            try await uploadAndSubmit(target)
            return
        }
        log.discard(key)
        afterLogChange(entry.intent.op)
        try await perform(entry.intent.op)
    }

    /// Cancels a send that has not reached the owner: stops its uploads
    /// (the source's upload task is cancelled), drops the row and makes the
    /// pending `send` throw `CancellationError`. Works for an upload in
    /// flight, one waiting for a reconnect, and a "Not Delivered" send.
    /// Returns false when there is nothing to cancel: an unknown key, or a
    /// send already submitted to the owner (it commits or fails on its own).
    @discardableResult
    public func cancelSend(_ key: IdempotencyKey) -> Bool {
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .sendMessage = entry.intent.op else { return false }
        let failed = if case .failed = entry.state { true } else { false }
        guard entry.isUploading || failed else { return false }
        uploads[key]?.task?.cancel()
        uploads[key] = nil
        log.discard(key)
        afterLogChange(entry.intent.op)
        return true
    }

    public func discardFailed(_ key: IdempotencyKey) {
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed = entry.state else { return }
        log.discard(key)
        uploads[key] = nil
        afterLogChange(entry.intent.op)
    }

    /// Marks everything up to the newest message as read (once per seq:
    /// the visible cursor already includes a pending cursor intent).
    public func markRead(_ id: ConversationID) {
        guard isOnline, let me = me?.id, let summary = mirror.conversations[id] else { return }
        let visible = rows.first { $0.id == id }?.summary.readCursors[me] ?? summary.readCursors[me] ?? 0
        guard summary.lastSeq > visible else { return }
        Task { try? await self.perform(.setReadCursor(conversation: id, seq: summary.lastSeq)) }
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [HomeSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await source.search(trimmed, limit: limit)
    }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        try await source.resolve(contact)
    }

    // MARK: Attachments

    /// Hashes a file (SHA-256, streamed), copies it into the blob cache and
    /// reads its display size, duration and poster frame. Runs off the main actor.
    public func prepareAttachment(fileURL: URL) async throws -> LocalAttachment {
        let root = blobCacheDirectory
        let prepared = try await AttachmentMedia.prepare(fileURL: fileURL, root: root)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    /// The same for in-memory bytes (a paste or a drop) of a UTType identifier.
    public func prepareAttachment(data: Data, typeIdentifier: String) async throws -> LocalAttachment {
        let root = blobCacheDirectory
        let prepared = try await AttachmentMedia.prepare(data: data, typeIdentifier: typeIdentifier, root: root)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    /// Sends text with attachments as one message: one pending intent with
    /// `key`, whose parts are the attachments in order, then the text when
    /// it is not blank. The row shows at once with `attachmentProgress`;
    /// the store uploads every attachment through the source, then submits
    /// `message.send` with the same key. An upload failure leaves the row
    /// "Not Delivered" (retry uploads only what is missing). Throws like
    /// `perform`, and `HomeAttachmentError` (nothing logged) for a file the
    /// owner would refuse.
    public func send(conversation: ConversationID, text: String, attachments: [LocalAttachment],
                     key: IdempotencyKey = .make()) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        var parts = attachments.map { MessagePart.attachment($0.ref) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
        guard !parts.isEmpty else { throw HomeRejection.invalid("empty_message") }
        guard parts.count <= HomeAttachmentPolicy.maxParts else {
            throw HomeAttachmentError.tooManyParts(limit: HomeAttachmentPolicy.maxParts)
        }
        for attachment in attachments {
            try HomeAttachmentPolicy.check(mimeType: attachment.ref.mimeType, byteCount: attachment.ref.byteCount,
                                           name: attachment.ref.name)
        }
        let op = HomeOp.sendMessage(conversation: conversation, parts: parts)
        guard !attachments.isEmpty else {
            try await perform(op, key: key)
            return
        }
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        log.setUploading(key, true)
        var unique: [LocalAttachment] = []
        for attachment in attachments where !unique.contains(where: { $0.ref.hash == attachment.ref.hash }) {
            unique.append(attachment)
            localFiles[attachment.ref.hash] = attachment.files
        }
        uploads[key] = UploadJob(conversation: conversation, attachments: unique)
        afterLogChange(op)
        try await uploadAndSubmit(key)
    }

    /// A local file holding the variant's bytes: this client's own copy when
    /// it has one, else the source's (which caches). The source needs the
    /// message part that references the hash; this finds it in the loaded
    /// transcripts (newest first). Idempotent and cancel-safe.
    public func fetchAttachment(_ ref: AttachmentRef, variant: AttachmentVariant) async throws -> URL {
        if let local = try await localAttachment(ref, variant: variant) { return local }
        guard let location = location(of: ref.hash) else { throw HomeRejection.invalid("attachment_not_loaded") }
        return try await source.fetch(ref, at: location, variant: variant)
    }

    /// The same when the caller knows where the attachment appears (a row's
    /// `messageID` and part index, a search hit).
    public func fetchAttachment(_ ref: AttachmentRef, at location: AttachmentLocation,
                                variant: AttachmentVariant) async throws -> URL {
        if let local = try await localAttachment(ref, variant: variant) { return local }
        return try await source.fetch(ref, at: location, variant: variant)
    }

    private func localAttachment(_ ref: AttachmentRef, variant: AttachmentVariant) async throws -> URL? {
        guard let files = localFiles[ref.hash] else { return nil }
        switch variant {
        case .original:
            return files.fileURL
        case .thumbnail(let maxPixel):
            return try await Self.localThumbnail(files, ref: ref, maxPixel: maxPixel)
        case .poster:
            guard let wanted = ref.poster else { throw HomeRejection.invalid("no_poster") }
            // The owner may have kept another device's poster for these bytes.
            guard let poster = files.posterURL, files.posterHash == wanted.hash else { return nil }
            return poster
        }
    }

    /// The newest committed message part that references `hash` (as the
    /// bytes or as a video's poster).
    func location(of hash: String) -> AttachmentLocation? {
        for (conversation, window) in mirror.windows {
            for message in window.messages.reversed() where !message.isRetracted {
                for (index, part) in message.parts.enumerated() {
                    guard case .attachment(let ref) = part, ref.hash == hash || ref.posterHash == hash else { continue }
                    return AttachmentLocation(conversation: conversation, message: message.id, partIndex: index)
                }
            }
        }
        return nil
    }

    private nonisolated static func localThumbnail(_ files: LocalAttachmentFiles, ref: AttachmentRef,
                                                   maxPixel: Int) async throws -> URL {
        try AttachmentMedia.localThumbnail(of: files, ref: ref, maxPixel: maxPixel)
    }

    /// Uploads the missing attachments of a logged send, then submits it.
    /// An interrupted upload (`ownerUnreachable`, `indeterminate`) keeps
    /// the row "sending" like a text send without an answer: it uploads
    /// again at once when the connection stayed up (once), else on the next
    /// reconnect, and throws `HomeSendState.pendingResend`. An
    /// `unknown_attachment` refusal (the owner swept the upload before the
    /// send arrived) uploads everything again and resends once under a new
    /// key; a second one leaves the row "Not Delivered". Throws
    /// `CancellationError` when `cancelSend` stopped it or its conversation
    /// left the inbox.
    private func uploadAndSubmit(_ first: IdempotencyKey) async throws {
        var key = first
        var uploadedAgain = false
        while true {
            // One pass at a time per send (a reconnect may race a retry).
            guard var job = uploads[key], job.task == nil else { return }
            job.attempt += 1
            job.waitingForReconnect = false
            job.active = true
            let uploaded = job.uploaded
            job.progress = Dictionary(uniqueKeysWithValues: job.attachments.map {
                ($0.ref.hash, uploaded.contains($0.ref.hash) ? 1.0 : 0.0)
            })
            let attempt = job.attempt
            let task = Task { [weak self] () -> HomeRejection? in
                await self?.uploadMissing(of: key, attempt: attempt)
            }
            job.task = task
            uploads[key] = job
            bumpTranscript(job.conversation)

            let failure = await task.value
            guard let entry = log.entries.first(where: { $0.intent.key == key }), uploads[key]?.attempt == attempt else {
                if !log.entries.contains(where: { $0.intent.key == key }) { uploads[key] = nil }
                throw CancellationError()
            }
            uploads[key]?.task = nil
            uploads[key]?.active = false
            uploads[key]?.progress = [:]
            if let failure {
                if failure == .ownerUnreachable || failure == .indeterminate {
                    if isOnline, uploads[key]?.resumedImmediately == false {
                        uploads[key]?.resumedImmediately = true
                        continue
                    }
                    uploads[key]?.waitingForReconnect = true
                    afterLogChange(entry.intent.op)
                    throw HomeSendState.pendingResend
                }
                log.setUploading(key, false)
                log.fail(key, failure)
                afterLogChange(entry.intent.op)
                throw failure
            }
            // The owner keeps the first record of a hash: send its mime type,
            // byte count and poster (or none), or it refuses attachment_mismatch.
            // The logged intent changes first, so the pending row shows the
            // parts that are sent.
            let op = Self.adopting(uploads[key]?.stored ?? [:], in: entry.intent.op)
            if op != entry.intent.op { log.replaceOp(key, with: op) }
            log.setUploading(key, false)
            uploads[key]?.reachedOwner = true
            afterLogChange(op)
            do {
                _ = try await submit(HomeIntent(key: key, op: op, issuedAt: entry.intent.issuedAt))
                return
            } catch let rejection as HomeRejection where rejection == .invalid("unknown_attachment") && !uploadedAgain {
                uploadedAgain = true
                let next = IdempotencyKey.make()
                restartUploads(from: key, as: next)
                afterLogChange(op)
                key = next
            }
        }
    }

    /// Uploads again every send whose upload a disconnect interrupted, in
    /// log order.
    private func resumeInterruptedUploads() {
        for entry in log.entries {
            let key = entry.intent.key
            guard uploads[key]?.waitingForReconnect == true else { continue }
            uploads[key]?.waitingForReconnect = false
            uploads[key]?.resumedImmediately = false
            Task { try? await self.uploadAndSubmit(key) }
        }
    }

    /// Moves a refused send's upload job to `newKey` with nothing uploaded,
    /// and rekeys its log entry in place.
    private func restartUploads(from key: IdempotencyKey, as newKey: IdempotencyKey) {
        guard var job = uploads.removeValue(forKey: key) else { return }
        job.uploaded = []
        job.stored = [:]
        job.reachedOwner = false
        uploads[newKey] = job
        log.rekey(key, to: newKey)
    }

    /// The op with each attachment part's mime type, byte count and poster
    /// taken from the owner's stored ref for its hash.
    static func adopting(_ stored: [String: AttachmentRef], in op: HomeOp) -> HomeOp {
        guard case .sendMessage(let conversation, let parts) = op else { return op }
        let adopted = parts.map { part -> MessagePart in
            guard case .attachment(var ref) = part, let record = stored[ref.hash] else { return part }
            ref.mimeType = record.mimeType
            ref.byteCount = record.byteCount
            ref.poster = record.poster
            return .attachment(ref)
        }
        return .sendMessage(conversation: conversation, parts: adopted)
    }

    /// Uploads, at most `uploadConcurrency` at once, every attachment of the
    /// job not uploaded yet. Successes count even when another one fails.
    private func uploadMissing(of key: IdempotencyKey, attempt: Int) async -> HomeRejection? {
        guard let job = uploads[key] else { return nil }
        let pending = job.attachments.filter { !job.uploaded.contains($0.ref.hash) }
        let source = self.source
        let conversation = job.conversation
        var failure: HomeRejection?
        await withTaskGroup(of: (String, Result<AttachmentRef, Error>).self) { group in
            var next = pending.makeIterator()
            func add(_ attachment: LocalAttachment) {
                let hash = attachment.ref.hash
                let upload = AttachmentUpload(conversation: conversation, fileURL: attachment.fileURL, ref: attachment.ref,
                                              posterURL: attachment.posterURL) { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.uploadProgressed(key, attempt: attempt, hash: hash, fraction) }
                }
                group.addTask {
                    do { return (hash, .success(try await source.upload(upload))) } catch { return (hash, .failure(error)) }
                }
            }
            for _ in 0..<Self.uploadConcurrency { if let attachment = next.next() { add(attachment) } }
            for await (hash, result) in group {
                guard uploads[key]?.attempt == attempt else { continue } // cancelled
                switch result {
                case .success(let stored) where stored.hash == hash:
                    uploads[key]?.uploaded.insert(hash)
                    uploads[key]?.stored[hash] = stored
                    if uploads[key]?.active == true { uploads[key]?.progress[hash] = 1 }
                    bumpUploadRow(key)
                case .success:
                    failure = failure ?? .invalid("attachment_hash_mismatch")
                case .failure(let error):
                    failure = failure ?? Self.rejection(for: error)
                }
                if let attachment = next.next() { add(attachment) }
            }
        }
        return failure
    }

    /// Ignores callbacks of an ended pass (a late callback after a failure,
    /// or from an earlier attempt during a retry).
    private func uploadProgressed(_ key: IdempotencyKey, attempt: Int, hash: String, _ fraction: Double) {
        guard let job = uploads[key], job.active, job.attempt == attempt, !job.uploaded.contains(hash) else { return }
        let value = min(max(fraction, 0), 1)
        let current = job.progress[hash] ?? 0
        // Forward only, and skip changes a progress ring cannot show.
        guard value > current, value - current >= 0.01 || value == 1 else { return }
        uploads[key]?.progress[hash] = value
        bumpUploadRow(key)
    }

    private func bumpUploadRow(_ key: IdempotencyKey) {
        if let conversation = uploads[key]?.conversation { bumpTranscript(conversation) }
    }

    private static func rejection(for error: Error) -> HomeRejection {
        if let rejection = error as? HomeRejection { return rejection }
        if error is URLError { return .ownerUnreachable }
        if error is CancellationError { return .indeterminate }
        return .invalid("attachment_upload_failed")
    }

    // MARK: Internals

    private func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        do {
            let result = try await source.submit(intent)
            log.acknowledge(intent.key, rev: result.rev)
            uploads[intent.key] = nil
            settle()
            afterLogChange(intent.op)
            return result
        } catch let rejection as HomeRejection {
            switch rejection {
            case .ownerUnreachable, .indeterminate:
                // Possibly committed: keep it and resend with the same key.
                log.markUnconfirmed(intent.key)
                if isOnline, let again = log.takeImmediateResend(intent.key) { enqueueResends([again]) }
                afterLogChange(intent.op)
                throw HomeSendState.pendingResend
            default:
                if case .sendMessage = intent.op {
                    log.fail(intent.key, rejection)
                } else {
                    log.discard(intent.key)
                }
                afterLogChange(intent.op)
                throw rejection
            }
        }
    }

    /// Resends run one at a time, in log order, so the owner sees them in order.
    private func enqueueResends(_ intents: [HomeIntent]) {
        pendingResends.append(contentsOf: intents)
        guard resendTask == nil, !pendingResends.isEmpty else { return }
        resendTask = Task { [weak self] in
            while let self, !self.pendingResends.isEmpty, !self.stopped {
                let next = self.pendingResends.removeFirst()
                _ = try? await self.submit(next)
            }
            self?.resendTask = nil
        }
    }

    func handle(_ event: HomeEvent) {
        switch event {
        case .connection(let state):
            let wasOnline = connection == .online
            connection = state
            if state != .online {
                log.markDisconnected()
                pendingResends.removeAll()
            }
            if state == .online, !wasOnline {
                enqueueResends(log.takeResends())
                resumeInterruptedUploads()
                for stream in mirror.stale { scheduleRefetch(stream) }
            }
            rebuildRows()
        case .typing(let id, let who, let on):
            var set = typing[id] ?? []
            if on { set.insert(who) } else { set.remove(who) }
            typing[id] = set.isEmpty ? nil : set
            rebuildRows()
        default:
            let outcome = mirror.apply(event)
            switch event {
            case .inbox(let snapshot):
                me = snapshot.me
                log.dropIntents(outside: Set(mirror.conversations.keys))
                for stream in mirror.stale { scheduleRefetch(stream) }
            case .conversationRemoved:
                log.dropIntents(outside: Set(mirror.conversations.keys))
            case .message(let message, _):
                bumpTranscript(message.conversation)
            default:
                break
            }
            settle()
            rebuildRows()
            if case .gap(let stream) = outcome { scheduleRefetch(stream) }
        }
    }

    private func scheduleRefetch(_ stream: HomeStream) {
        guard !refetching.contains(stream), !stopped else { return }
        Task { await self.refetch(stream) }
    }

    /// Fetches a stream until it is caught up (at most three tries per call).
    /// A failure leaves it stale; the next reconnect fetches it again.
    private func refetch(_ stream: HomeStream) async {
        guard !refetching.contains(stream), !stopped else { return }
        refetching.insert(stream)
        defer { refetching.remove(stream) }
        for _ in 0..<3 where !stopped {
            switch stream {
            case .inbox:
                guard let snapshot = try? await source.inbox() else { mirror.markStale(stream); return }
                let behind = mirror.apply(inbox: snapshot)
                me = snapshot.me
                settle()
                rebuildRows()
                for next in behind { scheduleRefetch(next) }
                return
            case .conversation(let id):
                guard let page = try? await source.snapshot(of: id, tail: Self.tailSize) else {
                    mirror.markStale(stream)
                    return
                }
                let outcome = mirror.apply(page: page)
                bumpTranscript(id)
                settle()
                rebuildRows()
                if outcome == .applied { return }
            }
        }
    }

    private func settle() {
        let settled = log.settle(against: mirror)
        guard !settled.isEmpty else { return }
        dropOrphanUploadJobs()
        for id in Array(transcriptVersion.keys) { bumpTranscript(id) }
    }

    /// Upload jobs live only as long as their log entry.
    private func dropOrphanUploadJobs() {
        guard !uploads.isEmpty else { return }
        let keys = Set(log.entries.map(\.intent.key))
        for key in uploads.keys where !keys.contains(key) { uploads[key] = nil }
    }

    private func afterLogChange(_ op: HomeOp) {
        dropOrphanUploadJobs()
        rebuildRows()
        if let id = op.conversation { bumpTranscript(id) }
    }

    private func bumpTranscript(_ id: ConversationID) {
        transcriptVersion[id, default: 0] += 1
    }

    private struct UploadJob {
        var conversation: ConversationID
        /// Unique by hash, in part order.
        var attachments: [LocalAttachment]
        var uploaded: Set<String> = []
        /// The owner's stored ref for each uploaded hash.
        var stored: [String: AttachmentRef] = [:]
        var progress: [String: Double] = [:]
        /// True while an upload pass runs.
        var active = false
        /// True once `message.send` went to the owner: a retry then needs a new key.
        var reachedOwner = false
        /// Counts upload passes; callbacks of an earlier pass are ignored.
        var attempt = 0
        /// The running pass (cancelled by `cancelSend`).
        var task: Task<HomeRejection?, Never>?
        /// A disconnect interrupted the last pass: the next reconnect resumes it.
        var waitingForReconnect = false
        /// The pass after an interruption already ran without a reconnect.
        var resumedImmediately = false
    }

    private func rebuildRows() {
        rows = mirror.inboxRows(log: log, typing: Set(typing.keys))
    }
}
