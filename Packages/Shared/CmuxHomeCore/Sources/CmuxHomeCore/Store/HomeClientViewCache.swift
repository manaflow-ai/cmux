import Foundation

/// Owns the client view state the Home cache keeps (drafts and scroll
/// anchors: never synced, never sent) and the coalesced writes of the
/// `HomeCache` snapshot. HomeStore owns one; the owner state that goes into
/// each snapshot (mirror, intent log, me) comes from `ownerSnapshot`.
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
    private(set) var scrollAnchors: [ConversationID: HomeScrollAnchor] = [:]
    private var pendingWrite: Task<Void, Never>?
    private var writesSuppressed = false

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
        scrollAnchors = snapshot.scroll
        body()
    }

    /// Writes the cache soon (coalesced), or at once with no delay.
    func scheduleWrite() {
        guard cache != nil, !writesSuppressed else { return }
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

    /// Writes the coalesced batch now (app quit, stop).
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    private func write() {
        guard let cache else { return }
        var snapshot = ownerSnapshot()
        snapshot.drafts = drafts
        snapshot.scroll = scrollAnchors
        try? cache.save(snapshot)
    }
}
