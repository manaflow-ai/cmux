import Foundation

/// Owns the client view state the Home cache keeps (drafts and scroll
/// anchors: never synced, never sent) and the coalesced writes of the
/// `HomeCache`. HomeStore owns one; the owner state that goes into each
/// write (mirror, intent log, me) comes from `ownerState`.
///
/// A write is scheduled only by a change to what the cache holds: a draft,
/// an attachment list or a scroll anchor here (equal values are no change),
/// and the store's mirror and log through `scheduleWrite()` when their cache
/// change counts moved. Owner events that change nothing the cache holds
/// (typing, a connection change, an owner recovery) schedule nothing, wake
/// nothing and build nothing, so disk writes follow new information
/// (speed-of-sound-DESIGN.md 3.5). A write costs the main actor only the
/// copy-on-write copies of a `HomeCacheState`; the `HomeCache` actor encodes
/// it and rewrites only the files that changed.
@MainActor
final class HomeClientViewCache {
    /// The client's durable copy, nil for none.
    let cache: HomeCache?
    /// How long writes are coalesced (zero hands each change to the cache actor at once: tests).
    let writeDelay: Duration
    private let clock: any Clock<Duration>
    /// The owner's state as the mirror has it, without the client's own state.
    var ownerState: @MainActor () -> HomeCacheState = { HomeCacheState() }

    private(set) var drafts: [ConversationID: String] = [:]
    private(set) var draftAttachments: [ConversationID: [HomeCachedDraftAttachment]] = [:]
    private(set) var scrollAnchors: [ConversationID: HomeScrollAnchor] = [:]
    private var pendingWrite: Task<Void, Never>?
    /// The newest state handed to the cache actor (``writeNow()``), awaited by ``flush()``.
    private var lastWrite: Task<Void, Never>?
    private var writesSuppressed = false
    /// Something changed since the last successful write (or the restore).
    private var dirty = false
    /// Numbers each state handed to the cache, so a late older write never replaces a newer one.
    private var sequence: UInt64 = 0
    /// This view cache's name at the cache actor, which orders each writer's states apart.
    private let writer = UUID()
    /// A coalesced write is waiting for its delay.
    var hasPendingWrite: Bool { pendingWrite != nil }

    init(cache: HomeCache?, writeDelay: Duration, clock: any Clock<Duration>) {
        self.cache = cache
        self.writeDelay = writeDelay
        self.clock = clock
    }

    /// Keeps the compose field's text; empty text clears it.
    func setDraft(_ text: String, for id: ConversationID) {
        let value: String? = text.isEmpty ? nil : text
        guard drafts[id] != value else { return }
        drafts[id] = value
        scheduleWrite()
    }

    /// Keeps the compose field's attachments; none clears them.
    func setDraftAttachments(_ attachments: [HomeCachedDraftAttachment], for id: ConversationID) {
        let value: [HomeCachedDraftAttachment]? = attachments.isEmpty ? nil : attachments
        guard draftAttachments[id] != value else { return }
        draftAttachments[id] = value
        scheduleWrite()
    }

    /// Where the reader is; nil when at the bottom.
    func setScrollAnchor(_ anchor: HomeScrollAnchor?, for id: ConversationID) {
        guard scrollAnchors[id] != anchor else { return }
        scrollAnchors[id] = anchor
        scheduleWrite()
    }

    /// Runs `body` (a restore) with writes suppressed, after taking the
    /// snapshot's client state.
    func restore(_ snapshot: HomeCacheSnapshot, _ body: () -> Void) {
        writesSuppressed = true
        defer { writesSuppressed = false }
        drafts = snapshot.drafts
        draftAttachments = snapshot.draftAttachments ?? [:]
        scrollAnchors = snapshot.scroll
        body()
    }

    /// Notes a change to what the cache holds and writes it soon
    /// (coalesced), or at once with no delay. Call it only for a real change.
    func scheduleWrite() {
        guard cache != nil, !writesSuppressed else { return }
        dirty = true
        guard pendingWrite == nil else { return }
        guard writeDelay > .zero else { return writeNow() }
        let clock = clock
        let delay = writeDelay
        // task-owner: one coalesced cache write; cancelled by writeNow, which writes at once
        pendingWrite = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.pendingWrite = nil
            self.writeNow()
        }
    }

    /// Hands what changed to the cache actor now, without waiting for the disk (sign-out, a zero
    /// coalescing delay); nothing when nothing changed. The actor encodes and writes it.
    func writeNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let cache, let taken = takeState() else { return }
        let writer = writer
        // task-owner: one write on the cache actor; ``flush()`` waits for the newest one
        lastWrite = Task { [weak self] in
            let wrote = await cache.write(taken.state, sequence: taken.sequence, writer: writer)
            if !wrote { self?.dirty = true }
        }
    }

    /// Writes the coalesced batch now and waits until the cache actor has it on disk (the quit's
    /// save step, tests), trying once more when that write failed; returns at once when nothing
    /// changed and no write is in flight.
    ///
    /// Waiting for the newest write is enough: every state holds all the earlier ones, and the
    /// actor drops an older state of this writer that reaches it later.
    func flush() async {
        writeNow()
        await lastWrite?.value
        // A failed write set `dirty` again and nothing else retries it: the quit tries once more.
        guard dirty else { return }
        writeNow()
        await lastWrite?.value
    }

    /// The state to write and its number, nil when nothing changed; clears `dirty` (a failed
    /// write sets it again).
    private func takeState() -> (state: HomeCacheState, sequence: UInt64)? {
        guard dirty else { return nil }
        dirty = false
        var state = ownerState()
        state.drafts = drafts
        state.draftAttachments = draftAttachments
        state.scroll = scrollAnchors
        sequence &+= 1
        return (state, sequence)
    }
}
