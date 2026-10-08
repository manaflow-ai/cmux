import Foundation
public import Observation

/// Why `perform` did not return a committed result.
public enum HomeSendState: Error, Hashable, Sendable {
    /// Sent, but the answer was lost; the store resends it with the same key
    /// (the owner applies it once). Do not send it again yourself.
    case pendingResend
    /// Its resends ran out without an answer. This is not a refusal (the
    /// owner never said no), so `onRefusal` does not hear of it. A send
    /// keeps a "Not Delivered" row (`retry` sends it again); when the send
    /// reached the owner the row's `mayHaveBeenDelivered` is true: say "may
    /// not have been delivered". Any other op leaves the log and reaches
    /// the host through `HomeStore.onUnanswered`.
    case unanswered
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
    /// Views showing each conversation's transcript now (`open` minus `close`).
    @ObservationIgnored private(set) var viewers: [ConversationID: Int] = [:]
    /// Bumps each time a conversation goes from shown nowhere to shown. A
    /// page read under an older epoch was read before a close: the close
    /// ended what the source kept for it (a cloud subscription), so the
    /// page is dropped and, when the conversation is shown again, read again.
    @ObservationIgnored private var openEpochs: [ConversationID: UInt64] = [:]
    /// The transcript read running per conversation (one at a time).
    @ObservationIgnored private var loads: [ConversationID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopped = false
    /// Where prepared attachments live (`<root>/<hash>/data.<ext>`).
    @ObservationIgnored public let blobCacheDirectory: URL
    /// Every attachment this client prepared, by hash (stays after the echo).
    @ObservationIgnored private var localFiles: [String: LocalAttachmentFiles] = [:]
    /// Sends with attachments, from the first upload until the owner
    /// commits them (kept after a refusal, so a retry can upload again).
    @ObservationIgnored private var uploads: [IdempotencyKey: UploadJob] = [:]

    /// Sends the owner has not decided yet, per conversation, in the order
    /// the user made them. A send goes to the owner only when it is first:
    /// every earlier send in its conversation was committed, refused,
    /// cancelled or failed its upload. So a text sent while a photo uploads
    /// waits for the photo, and the owner commits them in that order.
    @ObservationIgnored private var sendQueue: [ConversationID: [IdempotencyKey]] = [:]
    @ObservationIgnored private var turnWaiters: [IdempotencyKey: CheckedContinuation<Void, Never>] = [:]
    /// Delayed resends (and upload passes) of sends that got no answer
    /// while the connection stayed up, and how many each has had.
    @ObservationIgnored private var backoffTasks: [IdempotencyKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var backoffAttempts: [IdempotencyKey: Int] = [:]
    /// The periodic prune loop, and the pass running now. `prepare` waits
    /// for a running pass, and a pass skips while a prepare runs, so a
    /// prune never deletes a blob a prepare is reusing.
    @ObservationIgnored private var pruneLoop: Task<Void, Never>?
    @ObservationIgnored private var pruning: Task<Void, Never>?
    @ObservationIgnored private var preparing = 0

    /// Paces resends and cache pruning (tests pass a manual clock).
    @ObservationIgnored private let clock: any Clock<Duration>
    /// A send or op the owner refused after the call that made it returned
    /// (a resumed upload, a resend): the host says why. On the main actor.
    /// Each live view of the intent's conversation hears it through its
    /// registered hooks (`register(_:)`, what `HomeStoreBinding` does);
    /// this hears it only when no view of that conversation is registered.
    /// Resends that run out without an answer are not refusals and do not
    /// come here (see `HomeSendState.unanswered`).
    @ObservationIgnored public var onRefusal: ((HomeIntent, HomeRejection) -> Void)?
    /// An op other than a send (a tapback, a retraction, a read cursor)
    /// whose resends ran out without an answer: it left the log, so the
    /// change is gone from the transcript until an echo shows the owner
    /// did commit it. The host says it may not have gone through. On the
    /// main actor. Like `onRefusal`, it hears only what no registered view
    /// of the conversation hears. A send keeps its "Not Delivered" row and
    /// does not come here (see `HomeSendState.unanswered`).
    @ObservationIgnored public var onUnanswered: ((HomeIntent) -> Void)?
    /// The hooks of the views showing each conversation, held weakly (a
    /// view freed without `unregister` hears nothing and is pruned).
    @ObservationIgnored private var hooks: [ConversationID: [WeakConversationHooks]] = [:]
    /// Test seam: awaited before the prune deletes each blob directory.
    @ObservationIgnored var pruneWillDelete: (@Sendable (String) async -> Void)?

    /// When this store was created: temp files older than this are crash leftovers.
    @ObservationIgnored private let createdAt = Date()

    /// Blobs unused this long are deleted unless a pending send or this
    /// session's prepared attachments use them. The store reads only the
    /// copies this session prepared (`localFiles` lives in memory), so
    /// after a relaunch an old copy only saves a copy when the same file
    /// is attached again; the age bounds that.
    public static let blobCacheMaxAge: TimeInterval = 7 * 86_400
    /// Then the least recently used blobs go until the cache fits this cap.
    /// 1 GB holds ten maximum-size videos; macOS never purges Caches, so the
    /// cap is the only bound there, and on iOS it keeps the app well clear
    /// of the purge the OS does under disk pressure.
    public static let blobCacheMaxBytes = 1_000_000_000
    /// The cache is pruned at `start` and then this often while the store runs.
    public static let blobCachePruneInterval: Duration = .seconds(6 * 3_600)

    /// Delays between resends of a send that got no answer while the
    /// connection stayed up (after the one immediate resend). When they
    /// run out the send fails "Not Delivered" (`retry` resends it under
    /// the same key) and the sends queued behind it go.
    public static let resendBackoff: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    /// Attachment uploads in flight at once, per send.
    public static let uploadConcurrency = 3

    /// Messages fetched when a conversation opens.
    public static let tailSize = 60
    public static let pageSize = 80

    /// The client's durable copy (`HomeCache`), nil for none.
    @ObservationIgnored public let cache: HomeCache?
    /// How long cache writes are coalesced (zero writes at once: tests).
    @ObservationIgnored let cacheWriteDelay: Duration

    public init(source: any HomeSource, blobCacheDirectory: URL = HomeStore.defaultBlobCacheDirectory,
                clock: any Clock<Duration> = ContinuousClock(), cache: HomeCache? = nil,
                cacheWriteDelay: Duration = .milliseconds(250)) {
        self.source = source
        self.blobCacheDirectory = blobCacheDirectory
        self.clock = clock
        self.cache = cache
        self.cacheWriteDelay = cacheWriteDelay
    }

    /// Client view state the cache keeps (never synced, never sent).
    @ObservationIgnored private var drafts: [ConversationID: String] = [:]
    @ObservationIgnored private var scrollAnchors: [ConversationID: HomeScrollAnchor] = [:]
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    @ObservationIgnored private var restoringCache = false

    /// The unsent text of a conversation's compose field.
    public func draft(for id: ConversationID) -> String? { drafts[id] }

    /// Keeps the compose field's text; empty text clears it.
    public func setDraft(_ text: String, for id: ConversationID) {
        let value: String? = text.isEmpty ? nil : text
        guard drafts[id] != value else { return }
        drafts[id] = value
        scheduleCacheWrite()
    }

    public func scrollAnchor(for id: ConversationID) -> HomeScrollAnchor? { scrollAnchors[id] }

    /// Where the reader is; nil when at the bottom.
    public func setScrollAnchor(_ anchor: HomeScrollAnchor?, for id: ConversationID) {
        guard scrollAnchors[id] != anchor else { return }
        scrollAnchors[id] = anchor
        scheduleCacheWrite()
    }

    /// Writes the coalesced cache batch now (app quit), without stopping.
    public func flushCache() {
        cacheWrite?.cancel()
        cacheWrite = nil
        writeCache()
    }

    /// Shows what the cache holds before the owner answers.
    private func restoreCache() {
        guard let snapshot = cache?.load() else { return }
        restoringCache = true
        defer { restoringCache = false }
        mirror.seed(snapshot)
        me = mirror.me
        drafts = snapshot.drafts
        scrollAnchors = snapshot.scroll
        for send in snapshot.sends { log.restore(send.intent, failed: send.failed) }
        rebuildRows()
        for id in Set(snapshot.windows.keys).union(snapshot.sends.map(\.conversation)) { bumpTranscript(id) }
    }

    /// Writes the cache soon (coalesced), or at once with no delay.
    private func scheduleCacheWrite() {
        guard cache != nil, !restoringCache else { return }
        guard cacheWriteDelay > .zero else { return writeCache() }
        guard cacheWrite == nil else { return }
        let clock = clock
        let delay = cacheWriteDelay
        // task-owner: one coalesced cache write; cancelled by stop, which writes at once
        cacheWrite = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            self?.cacheWrite = nil
            self?.writeCache()
        }
    }

    /// The owner's state as the mirror has it, plus the client's own state.
    private func writeCache() {
        guard let cache else { return }
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me ?? mirror.me
        snapshot.conversations = mirror.conversations.values.sorted { $0.id.rawValue < $1.id.rawValue }
        snapshot.windows = mirror.windows.compactMapValues { window in
            window.messages.isEmpty ? nil : Array(window.messages.suffix(HomeCache.windowLimit))
        }
        snapshot.sends = log.entries.compactMap(HomeCachedSend.init)
        snapshot.drafts = drafts
        snapshot.scroll = scrollAnchors
        try? cache.save(snapshot)
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
        restoreCache()
        let clock = self.clock
        let interval = Self.blobCachePruneInterval
        pruneLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.pruneBlobCache()
                do { try await clock.sleep(for: interval) } catch { return }
            }
        }
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
        cacheWrite?.cancel()
        cacheWrite = nil
        writeCache()
        stopped = true
        eventTask?.cancel()
        eventTask = nil
        resendTask?.cancel()
        resendTask = nil
        pruneLoop?.cancel()
        pruneLoop = nil
        cancelBackoffs()
        for job in uploads.values { job.task?.cancel() }
        connection = .offline(since: Date())
        let waiters = turnWaiters.values
        turnWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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

    /// A view shows the conversation's transcript; each call pairs with one
    /// `close`. Loads the newest messages the first time it opens. Events
    /// committed while the page loads are buffered and kept.
    public func open(_ id: ConversationID) async {
        await beginOpen(id).value
    }

    /// `open` without waiting: the view counts as shown when this returns,
    /// so a `close` right after pairs with it. The task ends when the first
    /// page is in (at once when it already was).
    @discardableResult
    public func beginOpen(_ id: ConversationID) -> Task<Void, Never> {
        if viewers[id] == nil { openEpochs[id, default: 0] += 1 }
        viewers[id, default: 0] += 1
        if let running = loads[id] {
            // A read that started before a close reads again for this open.
            mirror.beginLoading(id)
            return running
        }
        guard mirror.windows[id] == nil else { return Task {} }
        mirror.beginLoading(id)
        return load(id)
    }

    /// A view of the conversation's transcript went away; pairs with one
    /// `open`. When the last one goes, the transcript is on screen nowhere:
    /// the store drops its window (the next `open` loads it again) and tells
    /// the source, which may end what it keeps for it (a cloud
    /// subscription, an archived conversation shown only while open).
    public func close(_ id: ConversationID) {
        guard let count = viewers[id] else { return }
        guard count <= 1 else {
            viewers[id] = count - 1
            return
        }
        viewers[id] = nil
        mirror.endTranscript(id)
        bumpTranscript(id)
        source.close(id)
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
    /// resends it with the same key. A `sendMessage` goes to the owner only
    /// after every earlier send in its conversation was decided (see
    /// `sendQueue`), so a burst of sends commits in the order made.
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
        if case .sendMessage(let conversation, _) = op {
            enqueueSend(key, in: conversation)
            await waitForTurn(key, in: conversation)
            // Cancelled or dropped while it waited.
            guard log.entries.contains(where: { $0.intent.key == key }), !stopped else { throw CancellationError() }
        }
        return try await submit(intent)
    }

    /// Retries a "Not Delivered" send. A send that went to the owner and
    /// got no answer (`indeterminate`, `ownerUnreachable`) goes again under
    /// the same key: the owner may have committed it, and its ledger
    /// replays that commit. A send whose attachment upload failed never
    /// reached the owner: it keeps its key (and its row) and uploads only
    /// the missing attachments. A send with attachments that the owner
    /// refused keeps its row position under a new key (the owner's ledger
    /// keeps the refused one) and uploads every attachment again first: an
    /// upload the owner still holds answers `exists` without sending the
    /// bytes. A same-key retry that gets `unknown_attachment` uploads again
    /// by itself, once, and throws `HomeSendState.pendingResend`. Another
    /// refused op is sent again as a new intent.
    public func retry(_ key: IdempotencyKey) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed(let rejection) = entry.state else { return }
        backoffAttempts[key] = nil
        uploads[key]?.resumedImmediately = false
        uploads[key]?.uploadedAfterSweep = false
        // Sent, but never answered: the owner may have committed it, so it
        // goes again under the same key (the owner's ledger replays it).
        if rejection == .indeterminate || rejection == .ownerUnreachable, uploads[key]?.reachedOwner ?? true {
            log.revive(key)
            if case .sendMessage(let conversation, _) = entry.intent.op {
                enqueueSend(key, in: conversation)
                afterLogChange(entry.intent.op)
                await waitForTurn(key, in: conversation)
                guard log.entries.contains(where: { $0.intent.key == key }), !stopped else { throw CancellationError() }
            }
            _ = try await submit(entry.intent)
            return
        }
        if let job = uploads[key] {
            var target = key
            if job.reachedOwner {
                target = .make()
                restartUploads(from: key, as: target)
            } else {
                log.setUploading(key, true)
            }
            enqueueSend(target, in: job.conversation)
            afterLogChange(entry.intent.op)
            try await uploadAndSubmit(target)
            return
        }
        log.discard(key)
        afterLogChange(entry.intent.op)
        try await perform(entry.intent.op)
    }

    /// Cancels a send the owner has not decided: stops its uploads (the
    /// source's upload task is cancelled), drops the row and makes the
    /// pending `send` or `perform` throw `CancellationError`. Works for an
    /// upload in flight or waiting for a reconnect, a send queued behind
    /// an earlier one, and a "Not Delivered" send. Returns false when there
    /// is nothing to cancel: an unknown key, or a send in flight to the
    /// owner or unanswered (it commits, or fails after its resends).
    @discardableResult
    public func cancelSend(_ key: IdempotencyKey) -> Bool {
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .sendMessage = entry.intent.op else { return false }
        let failed = if case .failed = entry.state { true } else { false }
        guard entry.isUploading || entry.isQueued || failed else { return false }
        uploads[key]?.task?.cancel()
        uploads[key] = nil
        cancelBackoff(key)
        pendingResends.removeAll { $0.key == key }
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
    /// reads its display size, duration and poster frame. Runs off the main
    /// actor (`@concurrent`). Opens a security-scoped URL itself. An image
    /// type the owner refuses (TIFF, HEIF) is converted to PNG or JPEG.
    ///
    /// Location metadata (photo GPS, a video's ISO 6709 location) is removed
    /// before hashing unless `keepLocation`; orientation stays. The host
    /// passes the user's Settings > Home toggle, key
    /// `home.attachments.keepLocation` (default off: strip), owned by the
    /// Home UI lane.
    public func prepareAttachment(fileURL: URL, keepLocation: Bool = false) async throws -> LocalAttachment {
        await beginPrepare()
        defer { preparing -= 1 }
        let root = blobCacheDirectory
        let prepared = try await AttachmentMedia.prepare(fileURL: fileURL, root: root, keepLocation: keepLocation)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    /// The same for in-memory bytes (a paste or a drop) of a UTType
    /// identifier, with the same `keepLocation`
    /// (`home.attachments.keepLocation`).
    public func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool = false) async throws -> LocalAttachment {
        await beginPrepare()
        defer { preparing -= 1 }
        let root = blobCacheDirectory
        let prepared = try await AttachmentMedia.prepare(data: data, typeIdentifier: typeIdentifier, root: root,
                                                         keepLocation: keepLocation)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    /// Waits for a running prune pass, then counts this prepare until its
    /// files are registered in `localFiles` (the prune's keep set).
    private func beginPrepare() async {
        while let running = pruning { await running.value }
        preparing += 1
    }

    /// Sends text with attachments as one message: one pending intent with
    /// `key`, whose parts are the attachments in order, then the text when
    /// it is not blank. The row shows at once with `attachmentProgress`;
    /// the store uploads every attachment through the source, then submits
    /// `message.send` with the same key, after every earlier send in the
    /// conversation. Each part takes the owner's stored mime type, byte
    /// count and poster first (the first upload of a hash wins). An upload
    /// failure leaves the row "Not Delivered" (retry uploads only what is
    /// missing); a disconnect keeps it sending and resumes on reconnect
    /// (`HomeSendState.pendingResend`); `cancelSend` stops it
    /// (`CancellationError`). Throws like `perform`, and
    /// `HomeAttachmentError` (nothing logged) for a file the owner would
    /// refuse.
    public func send(conversation: ConversationID, text: String, attachments: [LocalAttachment],
                     key: IdempotencyKey = .make()) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        // The owner's spelling and ranges, also for refs built outside prepare.
        let attachments = attachments.map { attachment -> LocalAttachment in
            var attachment = attachment
            attachment.ref = HomeAttachmentPolicy.normalized(attachment.ref)
            return attachment
        }
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
        enqueueSend(key, in: conversation)
        afterLogChange(op)
        try await uploadAndSubmit(key)
    }

    /// A local file holding the variant's bytes: this client's own copy when
    /// it has one, else the source's (which caches). The source needs the
    /// message part that references the hash; this finds it in the loaded
    /// transcript of `conversation` (newest first), the conversation of the
    /// row that shows it. Idempotent and cancel-safe.
    public func fetchAttachment(_ ref: AttachmentRef, variant: AttachmentVariant,
                                in conversation: ConversationID) async throws -> URL {
        if let local = try await localAttachment(ref, variant: variant) { return local }
        guard let location = location(of: ref.hash, in: conversation) else {
            if let standIn = try await localStandIn(ref, variant: variant) { return standIn }
            throw HomeRejection.invalid("attachment_not_loaded")
        }
        return try await source.fetch(ref, at: location, variant: variant)
    }

    /// For a pending row (the source cannot name it yet) whose part took
    /// another device's poster or preview (adoption changed its hash):
    /// this client's own poster frame or preview of the same bytes, or a
    /// local thumbnail at the preview size. Nil when there is none.
    private func localStandIn(_ ref: AttachmentRef, variant: AttachmentVariant) async throws -> URL? {
        guard let files = localFiles[ref.hash], FileManager.default.fileExists(atPath: files.fileURL.path) else { return nil }
        let exists = { (url: URL?) -> URL? in url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        switch variant {
        case .poster:
            return ref.poster == nil ? nil : exists(files.posterURL)
        case .preview:
            guard ref.preview != nil else { return nil }
            if let preview = exists(files.previewURL) { return preview }
            guard ref.mimeType.hasPrefix("image/") else { return nil }
            return try await Self.localThumbnail(files, ref: ref, maxPixel: HomeAttachmentPolicy.previewMaxPixel)
        case .original, .thumbnail:
            return nil
        }
    }

    /// The same when the caller knows where the attachment appears (a row's
    /// `messageID` and part index, a search hit).
    public func fetchAttachment(_ ref: AttachmentRef, at location: AttachmentLocation,
                                variant: AttachmentVariant) async throws -> URL {
        if let local = try await localAttachment(ref, variant: variant) { return local }
        return try await source.fetch(ref, at: location, variant: variant)
    }

    /// This client's copy, or nil when it has none or the OS purged it (the
    /// caller then fetches from the source).
    private func localAttachment(_ ref: AttachmentRef, variant: AttachmentVariant) async throws -> URL? {
        guard let files = localFiles[ref.hash] else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: files.fileURL.path) else {
            localFiles[ref.hash] = nil
            for id in Array(transcriptVersion.keys) { bumpTranscript(id) }
            return nil
        }
        if let poster = files.posterURL, !fm.fileExists(atPath: poster.path) {
            localFiles[ref.hash]?.posterURL = nil
            localFiles[ref.hash]?.posterHash = nil
            return try await localAttachment(ref, variant: variant)
        }
        if let preview = files.previewURL, !fm.fileExists(atPath: preview.path) {
            localFiles[ref.hash]?.previewURL = nil
            localFiles[ref.hash]?.previewHash = nil
            return try await localAttachment(ref, variant: variant)
        }
        AttachmentMedia.touch(files.fileURL.deletingLastPathComponent())
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
        case .preview:
            guard let wanted = ref.preview else { throw HomeRejection.invalid("no_preview") }
            guard let preview = files.previewURL, files.previewHash == wanted.hash else { return nil }
            return preview
        }
    }

    /// The newest committed message part in `conversation` that references
    /// `hash` (as the bytes or as a video's poster).
    func location(of hash: String, in conversation: ConversationID) -> AttachmentLocation? {
        guard let window = mirror.windows[conversation] else { return nil }
        for message in window.messages.reversed() where !message.isRetracted {
            for (index, part) in message.parts.enumerated() {
                guard case .attachment(let ref) = part,
                      ref.hash == hash || ref.posterHash == hash || ref.preview?.hash == hash else { continue }
                return AttachmentLocation(conversation: conversation, message: message.id, partIndex: index)
            }
        }
        return nil
    }

    @concurrent
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
    /// left the inbox, and `HomeSendState.unanswered` when its upload
    /// resends ran out.
    /// A pass nobody awaits (`background`: a resume on reconnect or after
    /// a backoff) reports a refusal through `onRefusal`.
    private func uploadAndSubmit(_ first: IdempotencyKey, background: Bool = false) async throws {
        var key = first
        do {
            try await uploadAndSubmitPasses(&key)
        } catch let rejection as HomeRejection {
            if background, let entry = log.entries.first(where: { $0.intent.key == key }), case .failed = entry.state {
                reportRefusal(entry.intent, rejection)
            }
            throw rejection
        }
    }

    private func uploadAndSubmitPasses(_ key: inout IdempotencyKey) async throws {
        var uploadedAgain = uploads[key]?.uploadedAfterSweep ?? false
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
            let passKey = key
            let task = Task { [weak self] () -> HomeRejection? in
                await self?.uploadMissing(of: passKey, attempt: attempt)
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
                    if isOnline, !scheduleBackoff(key, .upload) {
                        giveUp(key, failure, reachedOwner: uploads[key]?.reachedOwner ?? false)
                        throw HomeSendState.unanswered
                    }
                    afterLogChange(entry.intent.op)
                    throw HomeSendState.pendingResend
                }
                log.setUploading(key, false)
                log.fail(key, failure)
                leaveSendQueue(key)
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
            afterLogChange(op)
            await waitForTurn(key, in: uploads[key]?.conversation ?? job.conversation)
            guard log.entries.contains(where: { $0.intent.key == key }), !stopped else { throw CancellationError() }
            uploads[key]?.reachedOwner = true
            let swept = Self.swept
            do {
                _ = try await submit(HomeIntent(key: key, op: op, issuedAt: entry.intent.issuedAt),
                                     passing: uploadedAgain ? nil : swept)
                return
            } catch let rejection as HomeRejection where rejection == swept && !uploadedAgain {
                // Uploads again and resends under a new key in the same
                // place in the log and the conversation's queue.
                uploadedAgain = true
                let next = IdempotencyKey.make()
                restartUploads(from: key, as: next)
                uploads[next]?.uploadedAfterSweep = true
                replaceInSendQueue(key, with: next)
                afterLogChange(op)
                key = next
            }
        }
    }

    private func enqueueSend(_ key: IdempotencyKey, in conversation: ConversationID) {
        guard sendQueue[conversation]?.contains(key) != true else { return }
        sendQueue[conversation, default: []].append(key)
    }

    /// Returns once `key` is first in its conversation's queue, or left it.
    /// While it waits the entry is marked queued (never resent).
    private func waitForTurn(_ key: IdempotencyKey, in conversation: ConversationID) async {
        guard !stopped, let keys = sendQueue[conversation], keys.contains(key), keys.first != key else { return }
        log.setQueued(key, true)
        await withCheckedContinuation { turnWaiters[key] = $0 }
        log.setQueued(key, false)
    }

    /// The owner decided `key` (or it will never be sent): the next send in
    /// its conversation may go.
    private func leaveSendQueue(_ key: IdempotencyKey) {
        for (conversation, keys) in sendQueue where keys.contains(key) {
            removeFromSendQueue(conversation) { $0 == key }
        }
    }

    private func replaceInSendQueue(_ key: IdempotencyKey, with next: IdempotencyKey) {
        for (conversation, keys) in sendQueue {
            guard let index = keys.firstIndex(of: key) else { continue }
            sendQueue[conversation]?[index] = next
        }
    }

    private func removeFromSendQueue(_ conversation: ConversationID, where gone: (IdempotencyKey) -> Bool) {
        guard var keys = sendQueue[conversation] else { return }
        keys.removeAll(where: gone)
        sendQueue[conversation] = keys.isEmpty ? nil : keys
        if let first = keys.first, let waiter = turnWaiters.removeValue(forKey: first) { waiter.resume() }
    }

    /// Uploads again every send whose upload a disconnect interrupted, in
    /// log order.
    private func resumeInterruptedUploads() {
        for entry in log.entries {
            let key = entry.intent.key
            guard uploads[key]?.waitingForReconnect == true else { continue }
            uploads[key]?.resumedImmediately = false
            resumeUpload(key)
        }
    }

    private func resumeUpload(_ key: IdempotencyKey) {
        uploads[key]?.waitingForReconnect = false
        Task { try? await self.uploadAndSubmit(key, background: true) }
    }

    // MARK: Backoff

    private enum BackoffAction { case resend, upload }

    /// Runs `action` for `key` after its next `resendBackoff` delay on the
    /// store's clock, if still online then (a reconnect resends it
    /// anyway). False when the delays ran out.
    private func scheduleBackoff(_ key: IdempotencyKey, _ action: BackoffAction) -> Bool {
        let attempt = backoffAttempts[key, default: 0]
        guard attempt < Self.resendBackoff.count else { return false }
        backoffAttempts[key] = attempt + 1
        let delay = Self.resendBackoff[attempt]
        let clock = self.clock
        backoffTasks[key]?.cancel()
        backoffTasks[key] = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            // A newer backoff replaced this one while it woke: leave its handle.
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.backoffTasks[key] = nil
            guard self.isOnline else { return }
            switch action {
            case .resend:
                if let intent = self.log.takeResend(key) { self.enqueueResends([intent]) }
            case .upload:
                if self.uploads[key]?.waitingForReconnect == true { self.resumeUpload(key) }
            }
        }
        return true
    }

    /// The resends ran out: a send fails "Not Delivered" with the last
    /// answer (`retry` sends it again under the same key) and leaves the
    /// queue; another op is dropped and reported through `onUnanswered`.
    /// `reachedOwner`: the send itself went to the owner (not only its
    /// uploads), so the owner may have committed it
    /// (`TranscriptItem.mayHaveBeenDelivered`).
    private func giveUp(_ key: IdempotencyKey, _ rejection: HomeRejection, reachedOwner: Bool) {
        cancelBackoff(key)
        guard let entry = log.entries.first(where: { $0.intent.key == key }) else { return }
        if case .sendMessage = entry.intent.op {
            log.setUploading(key, false)
            log.fail(key, rejection, mayHaveBeenDelivered: reachedOwner)
        } else {
            log.discard(key)
        }
        uploads[key]?.waitingForReconnect = false
        leaveSendQueue(key)
        afterLogChange(entry.intent.op)
        if case .sendMessage = entry.intent.op {} else { reportUnanswered(entry.intent) }
    }

    private func cancelBackoff(_ key: IdempotencyKey) {
        backoffTasks.removeValue(forKey: key)?.cancel()
        backoffAttempts[key] = nil
    }

    /// Pending delays stop (a disconnect: the reconnect resends; `stop`).
    private func cancelBackoffs() {
        for task in backoffTasks.values { task.cancel() }
        backoffTasks.removeAll()
    }

    /// The owner swept an upload before the send that names it arrived.
    private static let swept = HomeRejection.invalid("unknown_attachment")

    /// A resend or a same-key retry got `unknown_attachment`: moves the send
    /// to a new key in the same place in the log and its conversation's
    /// queue, ready to upload everything again, once per send (and once per
    /// retry). Nil when it already did, or the send has no attachments.
    private func uploadAgainAfterSweep(_ key: IdempotencyKey) -> IdempotencyKey? {
        guard let job = uploads[key], job.reachedOwner, !job.uploadedAfterSweep else { return nil }
        cancelBackoff(key)
        let next = IdempotencyKey.make()
        restartUploads(from: key, as: next)
        uploads[next]?.uploadedAfterSweep = true
        if sendQueue[job.conversation]?.contains(key) == true {
            replaceInSendQueue(key, with: next)
        } else {
            enqueueSend(next, in: job.conversation)
        }
        return next
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
            ref.preview = record.preview
            return .attachment(ref)
        }
        return .sendMessage(conversation: conversation, parts: adopted)
    }

    /// Uploads, at most `uploadConcurrency` at once, every attachment of the
    /// job not uploaded yet. Successes count even when another one fails.
    /// A cached file the OS purged fails the pass with
    /// `attachment_file_missing` before anything uploads: the bytes are
    /// gone, so the user attaches the file again.
    private func uploadMissing(of key: IdempotencyKey, attempt: Int) async -> HomeRejection? {
        guard let job = uploads[key] else { return nil }
        let pending = job.attachments.filter { !job.uploaded.contains($0.ref.hash) }
        let fm = FileManager.default
        for attachment in pending {
            let posterGone = attachment.ref.poster != nil && attachment.posterURL.map { !fm.fileExists(atPath: $0.path) } ?? true
            let previewGone = attachment.ref.preview != nil && attachment.previewURL.map { !fm.fileExists(atPath: $0.path) } ?? true
            if !fm.fileExists(atPath: attachment.fileURL.path) || posterGone || previewGone {
                return .invalid("attachment_file_missing")
            }
        }
        let source = self.source
        let conversation = job.conversation
        var failure: HomeRejection?
        await withTaskGroup(of: (String, Result<AttachmentRef, Error>).self) { group in
            var next = pending.makeIterator()
            func add(_ attachment: LocalAttachment) {
                let hash = attachment.ref.hash
                let upload = AttachmentUpload(conversation: conversation, fileURL: attachment.fileURL, ref: attachment.ref,
                                              posterURL: attachment.posterURL,
                                              previewURL: attachment.previewURL) { [weak self] fraction in
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

    // MARK: Blob cache

    /// Prunes the blob cache (at `start`, then every
    /// `blobCachePruneInterval`): temp files left by a crash,
    /// blobs older than `blobCacheMaxAge`, then the least recently used
    /// blobs over `blobCacheMaxBytes`. Never deletes a blob that a pending
    /// send or this session's prepared attachments use.
    public func pruneBlobCache(now: Date = Date()) async {
        if let running = pruning {
            await running.value
            return
        }
        // A prepare may be reusing a blob it has not registered yet: the
        // next pass prunes.
        guard preparing == 0 else { return }
        var keep = Set<String>()
        func add(_ ref: AttachmentRef) {
            keep.insert(ref.hash)
            if let poster = ref.posterHash { keep.insert(poster) }
            if let preview = ref.preview?.hash { keep.insert(preview) }
        }
        for job in uploads.values { job.attachments.forEach { add($0.ref) } }
        for entry in log.entries {
            guard case .sendMessage(_, let parts) = entry.intent.op else { continue }
            for case .attachment(let ref) in parts { add(ref) }
        }
        for (hash, files) in localFiles {
            keep.insert(hash)
            if let poster = files.posterHash { keep.insert(poster) }
            if let preview = files.previewHash { keep.insert(preview) }
        }
        let root = blobCacheDirectory
        let tempsBefore = createdAt
        let willDelete = pruneWillDelete
        // The pass clears `pruning` itself, on the main actor, the moment
        // it ends: a waiting prepare never sees a finished pass (awaiting
        // a finished task does not suspend, so it would spin).
        let pass = Task { [weak self] in
            await Self.pruneBlobCache(at: root, keeping: keep, now: now, maxAge: Self.blobCacheMaxAge,
                                      maxBytes: Self.blobCacheMaxBytes, tempsBefore: tempsBefore, willDelete: willDelete)
            self?.pruning = nil
        }
        pruning = pass
        await pass.value
    }

    /// One pass over `<root>/<hash>/`: deletes `.incoming-*` files older
    /// than `tempsBefore`, blob directories not in `keep` unused for
    /// `maxAge`, then the least recently used ones not in `keep` while the
    /// cache is over `maxBytes`. "Used" is the directory's modification
    /// date, which a local fetch refreshes.
    @concurrent
    public nonisolated static func pruneBlobCache(at root: URL, keeping keep: Set<String>, now: Date,
                                                  maxAge: TimeInterval, maxBytes: Int, tempsBefore: Date,
                                                  willDelete: (@Sendable (String) async -> Void)? = nil) async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var blobs: [(name: String, url: URL, used: Date, bytes: Int)] = []
        for name in names {
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if name.hasPrefix(".incoming-") {
                if modified < tempsBefore { try? fm.removeItem(at: url) }
                continue
            }
            guard values?.isDirectory == true else { continue }
            blobs.append((name, url, modified, AttachmentMedia.directorySize(url)))
        }
        var total = blobs.reduce(0) { $0 + $1.bytes }
        for blob in blobs.sorted(by: { $0.used < $1.used }) where !keep.contains(blob.name) {
            guard now.timeIntervalSince(blob.used) > maxAge || total > maxBytes else { continue }
            await willDelete?(blob.name)
            try? fm.removeItem(at: blob.url)
            total -= blob.bytes
        }
    }

    // MARK: Internals

    /// `passing`: a refusal the caller handles itself (the log and the
    /// send queue stay as they are).
    private func submit(_ intent: HomeIntent, passing: HomeRejection? = nil) async throws -> HomeOpResult {
        do {
            let result = try await source.submit(intent)
            cancelBackoff(intent.key)
            log.acknowledge(intent.key, rev: result.rev)
            uploads[intent.key] = nil
            leaveSendQueue(intent.key)
            settle()
            afterLogChange(intent.op)
            return result
        } catch let rejection as HomeRejection {
            switch rejection {
            case .ownerUnreachable, .indeterminate:
                // Possibly committed: keep it and resend with the same key.
                // Online: once at once, then after each backoff delay,
                // then "Not Delivered" so later sends are not held forever.
                log.markUnconfirmed(intent.key)
                if isOnline {
                    if let again = log.takeImmediateResend(intent.key) {
                        enqueueResends([again])
                    } else if !scheduleBackoff(intent.key, .resend) {
                        giveUp(intent.key, rejection, reachedOwner: true)
                        throw HomeSendState.unanswered
                    }
                }
                afterLogChange(intent.op)
                throw HomeSendState.pendingResend
            default:
                if rejection == passing { throw rejection }
                // A resend or retry the owner cannot match to its uploads
                // (swept while the answer was lost): upload again, once.
                if rejection == Self.swept, case .sendMessage = intent.op, let next = uploadAgainAfterSweep(intent.key) {
                    afterLogChange(intent.op)
                    resumeUpload(next)
                    throw HomeSendState.pendingResend
                }
                cancelBackoff(intent.key)
                leaveSendQueue(intent.key)
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
                // Cancelled or dropped since it was queued.
                guard self.log.entries.contains(where: { $0.intent.key == next.key }) else { continue }
                do {
                    _ = try await self.submit(next)
                } catch let rejection as HomeRejection {
                    // Nobody awaits a resend: the host hears of the refusal.
                    self.reportRefusal(next, rejection)
                } catch {}
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
                cancelBackoffs()
            }
            if state == .online, !wasOnline {
                backoffAttempts.removeAll()
                enqueueResends(log.takeResends())
                resumeInterruptedUploads()
                for stream in mirror.stale { scheduleRefetch(stream) }
            }
            rebuildRows()
        case .ownerRecovered:
            // Offline intents wait for the reconnect, which resends them anyway.
            guard isOnline else { return }
            enqueueResends(log.takeResends())
            for stream in mirror.stale { scheduleRefetch(stream) }
            rebuildRows()
        case .intentsRevoked(let keys):
            // A resend already queued must not go either; one in flight is refused by its owner.
            pendingResends.removeAll { keys.contains($0.key) }
            for op in log.revoke(keys) {
                if let id = op.conversation { bumpTranscript(id) }
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
                dropOrphanUploadJobs()
                for stream in mirror.stale { scheduleRefetch(stream) }
            case .conversationRemoved:
                log.dropIntents(outside: Set(mirror.conversations.keys))
                dropOrphanUploadJobs()
            case .message(let message, _):
                bumpTranscript(message.conversation)
            case .conversationPage(let page):
                bumpTranscript(page.conversation.id)
            default:
                break
            }
            settle()
            rebuildRows()
            if case .gap(let stream) = outcome { scheduleRefetch(stream) }
        }
    }

    private func scheduleRefetch(_ stream: HomeStream) {
        guard !stopped else { return }
        switch stream {
        case .inbox:
            guard !refetching.contains(stream) else { return }
            Task { await self.refetchInbox() }
        case .conversation(let id):
            load(id)
        }
    }

    /// Fetches the inbox. A failure leaves it stale; the next reconnect
    /// fetches it again.
    private func refetchInbox() async {
        let stream = HomeStream.inbox
        guard !refetching.contains(stream), !stopped else { return }
        refetching.insert(stream)
        defer { refetching.remove(stream) }
        guard let snapshot = try? await source.inbox() else { mirror.markStale(stream); return }
        let behind = mirror.apply(inbox: snapshot)
        me = snapshot.me
        settle()
        rebuildRows()
        for next in behind { scheduleRefetch(next) }
    }

    /// The conversation's transcript read, or the one already running.
    @discardableResult
    private func load(_ id: ConversationID) -> Task<Void, Never> {
        if let running = loads[id] { return running }
        let task = Task {
            await self.readTranscript(id)
            self.loads[id] = nil
        }
        loads[id] = task
        return task
    }

    /// Reads the conversation's tail until it is caught up (at most three
    /// gaps per call), only while a view shows it. A failure leaves it
    /// stale; the next reconnect reads it again.
    ///
    /// Shown nowhere, nothing is read: a read would set up what only a
    /// `close` ends (a cloud subscription). Without a window a stale mark
    /// only holds intents back, and the inbox carries the summary, so it
    /// is cleared. A page that comes back after its transcript closed is
    /// dropped (the close ended the window and told the source); one that
    /// comes back after a close and a new open is read again, so the source
    /// sets up again what the close ended. A read that returns after its
    /// transcript closed closes the source again.
    private func readTranscript(_ id: ConversationID) async {
        let stream = HomeStream.conversation(id)
        var gaps = 0
        while gaps < 3, !stopped {
            guard viewers[id] != nil else {
                mirror.endTranscript(id)
                settle()
                rebuildRows()
                return
            }
            let epoch = openEpochs[id]
            let page = try? await source.snapshot(of: id, tail: Self.tailSize)
            guard !stopped else { return }
            guard viewers[id] != nil else {
                // Closed while the read ran. The source reads off the main
                // actor, so the close may have reached it before the read
                // set anything up (a cloud subscription), which the read
                // then did: close it again.
                source.close(id)
                return
            }
            guard openEpochs[id] == epoch else { continue }
            guard let page else {
                mirror.markStale(stream)
                return
            }
            let outcome = mirror.apply(page: page)
            bumpTranscript(id)
            settle()
            rebuildRows()
            if outcome == .applied { return }
            gaps += 1
        }
    }

    // MARK: Conversation hooks

    /// A view of `hooks.conversation` hears that conversation's refusals and
    /// unanswered ops nobody awaits until `unregister`, or until it is freed
    /// (the store holds it weakly). Registering it again does nothing.
    public func register(_ hooks: HomeConversationHooks) {
        let id = hooks.conversation
        var list = self.hooks[id, default: []].filter { $0.hooks != nil }
        if !list.contains(where: { $0.hooks === hooks }) { list.append(WeakConversationHooks(hooks: hooks)) }
        self.hooks[id] = list
    }

    /// The view stopped: it hears nothing more. Unregistering hooks that are
    /// not registered does nothing.
    public func unregister(_ hooks: HomeConversationHooks) {
        let id = hooks.conversation
        let list = self.hooks[id, default: []].filter { $0.hooks != nil && $0.hooks !== hooks }
        self.hooks[id] = list.isEmpty ? nil : list
    }

    /// Drops the entries of `conversation`'s hooks that were freed without
    /// `unregister` (a binding's deinit calls it).
    public func pruneHooks(for conversation: ConversationID) {
        let list = hooks[conversation, default: []].filter { $0.hooks != nil }
        hooks[conversation] = list.isEmpty ? nil : list
    }

    /// The live hooks of the intent's conversation, in registration order.
    /// Taken before any is called, so a hook that unregisters (or registers
    /// another) while it runs changes no delivery of this intent.
    private func liveHooks(for intent: HomeIntent) -> [HomeConversationHooks] {
        guard let id = intent.op.conversation else { return [] }
        pruneHooks(for: id)
        return hooks[id, default: []].compactMap(\.hooks)
    }

    /// A refusal nobody awaits: each live view of its conversation hears it
    /// once; with none, `onRefusal` does.
    func reportRefusal(_ intent: HomeIntent, _ rejection: HomeRejection) {
        let live = liveHooks(for: intent)
        guard !live.isEmpty else { onRefusal?(intent, rejection); return }
        for hooks in live { hooks.onRefusal(intent, rejection) }
    }

    /// An op that ran out of resends: each live view of its conversation
    /// hears it once; with none, `onUnanswered` does.
    func reportUnanswered(_ intent: HomeIntent) {
        let live = liveHooks(for: intent)
        guard !live.isEmpty else { onUnanswered?(intent); return }
        for hooks in live { hooks.onUnanswered(intent) }
    }

    /// Hook entries the store holds now, live or freed and not yet pruned (tests).
    var registeredHookCount: Int { hooks.values.reduce(0) { $0 + $1.count } }

    private func settle() {
        let settled = log.settle(against: mirror)
        guard !settled.isEmpty else { return }
        dropOrphanUploadJobs()
        for id in Array(transcriptVersion.keys) { bumpTranscript(id) }
    }

    /// Upload jobs and queued sends live only as long as their log entry.
    /// A waiter whose entry left resumes (and finds it gone).
    private func dropOrphanUploadJobs() {
        guard !uploads.isEmpty || !sendQueue.isEmpty else { return }
        let keys = Set(log.entries.map(\.intent.key))
        for key in uploads.keys where !keys.contains(key) { uploads[key] = nil }
        for conversation in Array(sendQueue.keys) { removeFromSendQueue(conversation) { !keys.contains($0) } }
        for key in Array(turnWaiters.keys) where !keys.contains(key) { turnWaiters.removeValue(forKey: key)?.resume() }
    }

    private func afterLogChange(_ op: HomeOp) {
        dropOrphanUploadJobs()
        rebuildRows()
        if let id = op.conversation { bumpTranscript(id) }
    }

    private func bumpTranscript(_ id: ConversationID) {
        transcriptVersion[id, default: 0] += 1
        scheduleCacheWrite()
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
        /// It already uploaded everything again after an `unknown_attachment`.
        var uploadedAfterSweep = false
    }

    private func rebuildRows() {
        rows = mirror.inboxRows(log: log, typing: Set(typing.keys))
        scheduleCacheWrite()
    }
}
