import Foundation

/// Owns the client view state the Home cache keeps (drafts and scroll
/// anchors: never synced, never sent) and the coalesced writes of the
/// `HomeCache` snapshot. HomeStore owns one; the owner state that goes into
/// each snapshot (mirror, intent log, me) comes from `ownerSnapshot`.
///
/// A write is scheduled only by a change to what the snapshot holds: a draft,
/// an attachment list or a scroll anchor here (equal values are no change),
/// and the store's mirror and log through `scheduleWrite()` when their cache
/// change counts moved. Owner events that change nothing the cache holds
/// (typing, a connection change, an owner recovery) schedule nothing, wake
/// nothing and build no snapshot, so disk writes follow new information
/// (speed-of-sound-DESIGN.md 3.5). No copy of the written snapshot is kept.
@MainActor
final class HomeClientViewCache {
    /// The client's durable copy, nil for none.
    let cache: HomeCache?
    /// How long writes are coalesced (zero writes at once: tests).
    let writeDelay: Duration
    private let clock: any Clock<Duration>
    /// The owner's state as the mirror has it, without the client's own state.
    var ownerSnapshot: @MainActor () -> HomeCacheSnapshot = { HomeCacheSnapshot() }

    private(set) var drafts: [ConversationID: String] = [:]
    private(set) var draftAttachments: [ConversationID: [HomeCachedDraftAttachment]] = [:]
    private(set) var scrollAnchors: [ConversationID: HomeScrollAnchor] = [:]
    private var pendingWrite: Task<Void, Never>?
    private var writesSuppressed = false
    /// Something changed since the last successful write (or the restore).
    private var dirty = false
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

    /// Notes a change to what the snapshot holds and writes the cache soon
    /// (coalesced), or at once with no delay. Call it only for a real change.
    func scheduleWrite() {
        guard cache != nil, !writesSuppressed else { return }
        dirty = true
        guard writeDelay > .zero else { return write() }
        guard pendingWrite == nil else { return }
        let clock = clock
        let delay = writeDelay
        // task-owner: one coalesced cache write; cancelled by flush, which writes at once
        pendingWrite = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            self?.pendingWrite = nil
            self?.write()
        }
    }

    /// Writes the coalesced batch now (app quit, stop); nothing when nothing changed.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    private func write() {
        guard let cache, dirty else { return }
        var snapshot = ownerSnapshot()
        snapshot.drafts = drafts
        snapshot.draftAttachments = draftAttachments.isEmpty ? nil : draftAttachments
        snapshot.scroll = scrollAnchors
        do {
            try cache.save(snapshot)
            dirty = false
        } catch {
            // Still dirty: the next change or the flush at quit writes again.
        }
    }
}
