import Foundation
import Observation

/// Main-actor state for one conversation: the message window, its rendered
/// row projection, agent presence, pagination, and the send pipeline.
///
/// The store is platform-agnostic; iOS and macOS surfaces both drive it.
/// It depends only on the ``ChatEventSource`` seam, injected at init.
///
/// Lifecycle: the owning view runs ``run()`` inside its `.task` modifier so
/// the live subscription is structured — it is cancelled automatically when
/// the view disappears, and the store never stores a `Task` it could leak.
///
/// ```swift
/// @State private var store: ChatConversationStore
/// var body: some View {
///     ChatTranscriptList(rows: store.rows)
///         .task { await store.run() }
/// }
/// ```
@MainActor
@Observable
public final class ChatConversationStore {
    /// Identity and header state of the session being shown.
    public private(set) var descriptor: ChatSessionDescriptor

    /// The rendered transcript rows, oldest first. This is the only thing
    /// the list view iterates; rows are immutable snapshots.
    public private(set) var rows: [ChatTranscriptRow] = []

    /// Live agent presence (drives the typing indicator and header dot).
    public private(set) var agentState: ChatAgentState

    /// Whether older history exists beyond the current window.
    public private(set) var hasMoreHistory = false

    /// True when paging stopped at the Mac's cache head while older
    /// transcript still exists on disk; the UI shows an "earlier history is
    /// on your Mac" cell instead of a loading sentinel.
    public private(set) var historyTruncatedAtHead = false

    /// Whether an older-history page is currently being fetched.
    public private(set) var isLoadingOlder = false

    /// Whether the initial history load has completed at least once.
    public private(set) var hasLoadedInitialHistory = false

    /// Whether the live event stream is currently down. The stream ends
    /// when the underlying connection closes; ``run()`` sets this and
    /// retries while it remains active.
    public private(set) var isConnected = false

    /// Human-readable description of the most recent failure, for a
    /// non-blocking error surface. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored private var messages: [ChatMessage] = []
    @ObservationIgnored private var pending: [ChatPendingOutbound] = []
    @ObservationIgnored private var firstUnreadSeq: Int?
    @ObservationIgnored private let source: any ChatEventSource
    @ObservationIgnored private let projector: ChatTranscriptProjector
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let maxWindowCount: Int
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pendingCounter = 0

    /// Creates a conversation store.
    ///
    /// - Parameters:
    ///   - descriptor: The session to show.
    ///   - source: The conversation data seam.
    ///   - lastReadSeq: Highest seq the user has already seen, used to place
    ///     the unread separator on first load; `nil` shows no separator.
    ///   - projector: Row projection policy (grouping interval, calendar).
    ///   - pageSize: History page size for initial load and `loadOlder()`.
    ///   - maxWindowCount: Cap on the in-memory message window; older
    ///     messages fall out and become pageable history again.
    ///   - now: Clock seam for tests; defaults to the wall clock.
    public init(
        descriptor: ChatSessionDescriptor,
        source: any ChatEventSource,
        lastReadSeq: Int? = nil,
        projector: ChatTranscriptProjector = ChatTranscriptProjector(),
        pageSize: Int = 100,
        maxWindowCount: Int = 600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.descriptor = descriptor
        self.agentState = descriptor.state
        self.source = source
        self.projector = projector
        self.pageSize = pageSize
        self.maxWindowCount = maxWindowCount
        self.now = now
        self.lastReadSeqAtActivation = lastReadSeq
    }

    @ObservationIgnored private let lastReadSeqAtActivation: Int?

    /// Follows the live event stream until cancelled, loading history
    /// inside each subscription so no event falls into a fetch/subscribe
    /// gap. Run this from the owning view's `.task` modifier.
    ///
    /// If the stream ends while the task is still active (connection drop),
    /// the store marks itself disconnected and resubscribes; the event
    /// source owns backoff policy.
    public func run() async {
        while !Task.isCancelled {
            // Subscribe FIRST: events emitted while the history fetch is in
            // flight buffer in the stream and replay after the merge (the
            // window dedups by message id), instead of being dropped.
            let stream = await source.events(sessionID: descriptor.id)
            isConnected = true
            let hadHistory = hasLoadedInitialHistory
            await loadInitialHistoryIfNeeded()
            if hadHistory {
                // Reconnect: merge whatever the window missed while down.
                await resyncTail()
            }
            for await event in stream {
                apply(event)
            }
            isConnected = false
            guard !Task.isCancelled else { return }
        }
    }

    /// Fetches one older page and prepends it to the window.
    public func loadOlder() async {
        guard hasMoreHistory, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let oldestSeq = messages.first?.seq
            let page = try await source.history(
                sessionID: descriptor.id,
                beforeSeq: oldestSeq,
                limit: pageSize
            )
            // Re-check the anchor: an append may have raced the fetch.
            guard messages.first?.seq == oldestSeq else { return }
            if page.messages.isEmpty {
                // The Mac's cache head: nothing more is servable even when
                // older transcript exists on disk. Stop paging and surface
                // the honest "earlier history is on your Mac" state.
                hasMoreHistory = false
                historyTruncatedAtHead = page.hasMore
            } else {
                messages.insert(contentsOf: page.messages, at: 0)
                hasMoreHistory = page.hasMore
            }
            lastErrorDescription = nil
            reproject()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Sends a prompt with optional attachments, tracking it optimistically
    /// as a pending row until the transcript echoes it back.
    ///
    /// - Parameters:
    ///   - text: The prompt text. Ignored when empty and no attachments.
    ///   - attachments: Images to deliver ahead of the prompt.
    public func send(text: String, attachments: [ChatOutboundAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        pendingCounter += 1
        let item = ChatPendingOutbound(
            id: "local-\(pendingCounter)",
            text: trimmed,
            attachmentCount: attachments.count,
            createdAt: now(),
            delivery: .sending
        )
        pending.append(item)
        reproject()
        do {
            try await source.send(text: trimmed, attachments: attachments, sessionID: descriptor.id)
            updatePending(id: item.id, delivery: .delivered)
            lastErrorDescription = nil
        } catch {
            updatePending(id: item.id, delivery: .failed(error.localizedDescription))
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Retries a failed pending send.
    ///
    /// - Parameter pendingID: The pending row to retry.
    public func retry(pendingID: String) async {
        guard let index = pending.firstIndex(where: { $0.id == pendingID }),
              case .failed = pending[index].delivery else { return }
        let item = pending[index]
        updatePending(id: pendingID, delivery: .sending)
        do {
            try await source.send(text: item.text, attachments: [], sessionID: descriptor.id)
            updatePending(id: pendingID, delivery: .delivered)
            lastErrorDescription = nil
        } catch {
            updatePending(id: pendingID, delivery: .failed(error.localizedDescription))
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Removes a failed pending send without retrying it.
    ///
    /// - Parameter pendingID: The pending row to discard.
    public func discard(pendingID: String) {
        pending.removeAll { $0.id == pendingID }
        reproject()
    }

    /// Interrupts the agent.
    ///
    /// - Parameter hard: `false` for the polite interrupt, `true` for
    ///   ctrl-C.
    public func interrupt(hard: Bool = false) async {
        do {
            try await source.interrupt(sessionID: descriptor.id, hard: hard)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Answers a pending question or permission card by option index.
    ///
    /// - Parameter optionIndex: Zero-based index of the chosen option.
    public func answer(optionIndex: Int) async {
        do {
            try await source.answer(optionIndex: optionIndex, sessionID: descriptor.id)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    // MARK: - Event application

    private func loadInitialHistoryIfNeeded() async {
        guard !hasLoadedInitialHistory else { return }
        do {
            let page = try await source.history(
                sessionID: descriptor.id,
                beforeSeq: nil,
                limit: pageSize
            )
            messages = page.messages
            hasMoreHistory = page.hasMore
            hasLoadedInitialHistory = true
            if let lastRead = lastReadSeqAtActivation,
               let firstUnread = page.messages.first(where: { $0.seq > lastRead }) {
                firstUnreadSeq = firstUnread.seq
            }
            lastErrorDescription = nil
            reproject()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    /// After a stream drop, fetches the newest page and merges anything the
    /// window missed while disconnected.
    private func resyncTail() async {
        do {
            let page = try await source.history(
                sessionID: descriptor.id,
                beforeSeq: nil,
                limit: pageSize
            )
            guard let newestKnown = messages.last?.seq else {
                reconcilePending(against: page.messages)
                messages = page.messages
                hasMoreHistory = page.hasMore
                reproject()
                return
            }
            let missed = page.messages.filter { $0.seq > newestKnown }
            if !missed.isEmpty {
                reconcilePending(against: missed)
                appendToWindow(missed)
            }
            // Carry in-place completions (tool results that resolved while
            // disconnected) for messages already in the window.
            var didUpdate = false
            for message in page.messages where message.seq <= newestKnown {
                if let index = messages.firstIndex(where: { $0.id == message.id }),
                   messages[index] != message {
                    messages[index] = message
                    didUpdate = true
                }
            }
            if didUpdate { reproject() }
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func apply(_ event: ChatSessionEvent) {
        switch event {
        case .appended(let newMessages):
            reconcilePending(against: newMessages)
            appendToWindow(newMessages)
        case .updated(let changed):
            var didChange = false
            for message in changed {
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index] = message
                    didChange = true
                }
            }
            if didChange { reproject() }
        case .stateChanged(let state):
            agentState = state
        case .descriptorChanged(let descriptor):
            self.descriptor = descriptor
            agentState = descriptor.state
        }
    }

    private func appendToWindow(_ newMessages: [ChatMessage]) {
        // Dedup by id: a live event can replay content the history fetch in
        // the same subscription cycle already merged.
        let knownIDs = Set(messages.suffix(64).map(\.id))
        let fresh = newMessages.filter { !knownIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        if messages.count > maxWindowCount {
            messages.removeFirst(messages.count - maxWindowCount)
            hasMoreHistory = true
        }
        reproject()
    }

    /// Drops optimistic rows whose prompt text has echoed back through the
    /// transcript as a real user message.
    private func reconcilePending(against newMessages: [ChatMessage]) {
        guard !pending.isEmpty else { return }
        for message in newMessages {
            guard message.role == .user, case .prose(let prose) = message.kind else { continue }
            let echoed = prose.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let index = pending.firstIndex { item in
                if item.text == echoed { return true }
                // The transcript copy may be budget-truncated ("…" suffix)
                // or a paste placeholder; match on the echoed prefix so long
                // prompts still reconcile.
                if echoed.hasSuffix("…"), echoed.count > 64,
                   item.text.hasPrefix(echoed.dropLast()) {
                    return true
                }
                return false
            }
            if let index {
                pending.remove(at: index)
            }
        }
    }

    private func updatePending(id: String, delivery: ChatDeliveryState) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].delivery = delivery
        reproject()
    }

    private func reproject() {
        rows = projector.rows(
            messages: messages,
            pending: pending,
            firstUnreadSeq: firstUnreadSeq
        )
    }
}
