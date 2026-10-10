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
    /// `.connecting` and `.offline` refuse new ops, except sends: those wait
    /// for the reconnect (`offlineSendDeadline`).
    public internal(set) var connection: HomeConnection = .connecting
    public private(set) var rows: [InboxRow] = []
    /// Increments whenever a transcript's visible items change.
    public private(set) var transcriptVersion: [ConversationID: Int] = [:]
    /// Conversations an owner named this session (its inbox, an event, a
    /// message or a page), as opposed to the cache's copy (cx-ebm.55).
    /// Observable: a send held for one goes when it is confirmed.
    public private(set) var confirmed: Set<ConversationID> = []
    /// Conversations the cache seeded at launch.
    @ObservationIgnored var seeded: Set<ConversationID> = []
    /// Conversations that got the text typed in a gone cache-only one, until their view says so.
    @ObservationIgnored var carriedDrafts: Set<ConversationID> = []
    public internal(set) var me: Participant?
    public internal(set) var typing: [ConversationID: Set<ParticipantID>] = [:]

    @ObservationIgnored public let source: any HomeSource
    @ObservationIgnored var mirror = HomeMirror()
    @ObservationIgnored var log = IntentLog()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored var resendTask: Task<Void, Never>?
    @ObservationIgnored var pendingResends: [HomeIntent] = []
    @ObservationIgnored var refetching: Set<HomeStream> = []
    /// Which transcripts are on screen and the reads that fill them.
    @ObservationIgnored var pager = HomeTranscriptPager()
    /// Views showing each conversation's transcript now (tests).
    var viewers: [ConversationID: Int] { pager.viewers }
    @ObservationIgnored var stopped = false
    /// Where prepared attachments live (`<root>/<hash>/data.<ext>`).
    @ObservationIgnored public let blobCacheDirectory: URL
    /// Every attachment this client prepared, by hash (stays after the echo).
    @ObservationIgnored var localFiles: [String: LocalAttachmentFiles] = [:]
    /// Sends with attachments, from the first upload until the owner
    /// commits them (kept after a refusal, so a retry can upload again).
    @ObservationIgnored var uploads: [IdempotencyKey: UploadJob] = [:]

    /// Sends the owner has not decided yet, per conversation, in the order
    /// the user made them. A send goes to the owner only when it is first:
    /// every earlier send in its conversation was committed, refused,
    /// cancelled or failed its upload. So a text sent while a photo uploads
    /// waits for the photo, and the owner commits them in that order.
    @ObservationIgnored var sendQueue: [ConversationID: [IdempotencyKey]] = [:]
    @ObservationIgnored var turnWaiters: [IdempotencyKey: CheckedContinuation<Void, Never>] = [:]
    /// Delayed resends (and upload passes) of sends that got no answer
    /// while the connection stayed up, and how many each has had.
    @ObservationIgnored var backoffTasks: [IdempotencyKey: Task<Void, Never>] = [:]
    @ObservationIgnored var backoffAttempts: [IdempotencyKey: Int] = [:]
    /// Sends made while offline that have not gone to the owner yet, and
    /// the deadline of each send made while offline.
    @ObservationIgnored var offlineQueued: Set<IdempotencyKey> = []
    /// Sends an attempt may have delivered (sent, no answer): a later
    /// attempt that sends nothing (`HomeOwnerOffline`) keeps them "may have
    /// been delivered".
    @ObservationIgnored var possiblySent: Set<IdempotencyKey> = []
    @ObservationIgnored var offlineDeadlines: [IdempotencyKey: Task<Void, Never>] = [:]
    /// The periodic prune loop, and the pass running now. `prepare` waits
    /// for a running pass, and a pass skips while a prepare runs, so a
    /// prune never deletes a blob a prepare is reusing.
    @ObservationIgnored private var pruneLoop: Task<Void, Never>?
    @ObservationIgnored var pruning: Task<Void, Never>?
    @ObservationIgnored var preparing = 0

    /// Paces resends and cache pruning (tests pass a manual clock).
    @ObservationIgnored let clock: any Clock<Duration>
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
    /// The hooks of the views showing each conversation (weakly held).
    @ObservationIgnored var hookRegistry = HomeConversationHookRegistry()
    /// Test seam: awaited before the prune deletes each blob directory.
    @ObservationIgnored var pruneWillDelete: (@Sendable (String) async -> Void)?

    /// When this store was created: temp files older than this are crash leftovers.
    @ObservationIgnored let createdAt = Date()

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
    /// Drafts, scroll anchors and the coalesced cache writes.
    @ObservationIgnored let viewCache: HomeClientViewCache

    public init(source: any HomeSource, blobCacheDirectory: URL = HomeStore.defaultBlobCacheDirectory,
                clock: any Clock<Duration> = ContinuousClock(), cache: HomeCache? = nil,
                cacheWriteDelay: Duration = .milliseconds(250)) {
        self.source = source
        self.blobCacheDirectory = blobCacheDirectory
        self.clock = clock
        self.cache = cache
        self.viewCache = HomeClientViewCache(cache: cache, writeDelay: cacheWriteDelay, clock: clock)
        viewCache.ownerSnapshot = { [weak self] in self?.ownerCacheSnapshot() ?? HomeCacheSnapshot() }
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
        viewCache.flush()
        stopped = true
        eventTask?.cancel()
        eventTask = nil
        resendTask?.cancel()
        resendTask = nil
        pruneLoop?.cancel()
        pruneLoop = nil
        cancelBackoffs()
        cancelOfflineDeadlines()
        for job in uploads.values { job.task?.cancel() }
        connection = .offline(since: Date())
        let waiters = turnWaiters.values
        turnWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Reading

    public var isOnline: Bool { connection == .online && !stopped }

    public func summary(_ id: ConversationID) -> ConversationSummary? { mirror.conversations[id] }
    /// The owner's own inbox lists the conversations now: not the cache's copy
    /// from before the owner answered, not one behind a failed refetch.
    public var isInboxCurrent: Bool { !mirror.isStale(.inbox) }
    /// An owner named `id` this session. A conversation only the cache knows
    /// is not confirmed: its Chief home may have been made again (cx-ebm.55).
    public func isConfirmed(_ id: ConversationID) -> Bool { confirmed.contains(id) }
    /// The cache seeded `id` at launch and no owner has named it since: on the
    /// owner's current inbox, a conversation the owner does not have.
    public func isCacheOnly(_ id: ConversationID) -> Bool { seeded.contains(id) && !confirmed.contains(id) }

    /// Home moved the text typed in a gone cache-only conversation to `id`.
    public func noteCarriedDraft(to id: ConversationID) { carriedDrafts.insert(id) }
    /// Whether `id` got such text since its view last asked (one answer per carry).
    public func takeCarriedDraft(_ id: ConversationID) -> Bool { carriedDrafts.remove(id) != nil }

    func confirm(_ ids: some Sequence<ConversationID>) {
        let new = Set(ids).subtracting(confirmed)
        if !new.isEmpty { confirmed.formUnion(new) }
    }

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

    func settle() {
        let settled = log.settle(against: mirror)
        guard !settled.isEmpty else { return }
        dropOrphanUploadJobs()
        for id in Array(transcriptVersion.keys) { bumpTranscript(id) }
    }

    /// Upload jobs and queued sends live only as long as their log entry.
    /// A waiter whose entry left resumes (and finds it gone).
    func dropOrphanUploadJobs() {
        if !offlineDeadlines.isEmpty {
            let keys = Set(log.entries.map(\.intent.key))
            for key in Array(offlineDeadlines.keys) where !keys.contains(key) { endOfflineDeadline(key) }
        }
        guard !uploads.isEmpty || !sendQueue.isEmpty else { return }
        let keys = Set(log.entries.map(\.intent.key))
        for key in uploads.keys where !keys.contains(key) { uploads[key] = nil }
        for conversation in Array(sendQueue.keys) { removeFromSendQueue(conversation) { !keys.contains($0) } }
        for key in Array(turnWaiters.keys) where !keys.contains(key) { turnWaiters.removeValue(forKey: key)?.resume() }
    }

    func afterLogChange(_ op: HomeOp) {
        dropOrphanUploadJobs()
        rebuildRows()
        if let id = op.conversation { bumpTranscript(id) }
    }

    func bumpTranscript(_ id: ConversationID) {
        transcriptVersion[id, default: 0] += 1
        scheduleCacheWrite()
    }

    struct UploadJob {
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

    func rebuildRows() {
        rows = mirror.inboxRows(log: log, typing: Set(typing.keys))
        scheduleCacheWrite()
    }
}
