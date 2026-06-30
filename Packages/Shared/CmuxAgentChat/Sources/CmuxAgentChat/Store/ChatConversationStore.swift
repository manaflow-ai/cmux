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

    /// True when the initial history fetch failed (the transcript may be
    /// unknown to the Mac); the UI offers a retry instead of a spinner.
    public private(set) var initialLoadFailed = false

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

    /// The row id of the latest optimistic outbound prompt, used by chat
    /// surfaces to focus the just-sent message instead of leaving it buried
    /// against the composer.
    public private(set) var latestOutboundFocusRowID: String?

    @ObservationIgnored private var messages: [ChatMessage] = []
    @ObservationIgnored private var pending: [ChatPendingOutbound] = []
    /// Live, not-yet-committed preview of the agent's in-progress prose for the
    /// current turn, scraped from the rendered terminal screen. Held outside
    /// ``messages`` (so it never collides with window dedup/paging/seq) and
    /// rendered as a trailing agent bubble. Cleared the instant the authoritative
    /// agent prose lands via ``ChatSessionEvent/appended`` or an explicit
    /// ``ChatSessionEvent/streamingProse`` `nil`, so it never duplicates a real
    /// message.
    @ObservationIgnored private var streamingMessage: ChatMessage?
    @ObservationIgnored private var firstUnreadSeq: Int?
    /// Terminal command-blocks for a `.terminal`-kind session, upserted by
    /// id; `terminalBlockOrder` preserves arrival order. Unused (and the
    /// reproject below ignores them) for agent sessions.
    @ObservationIgnored private var terminalBlocks: [Int: TerminalCommandBlock] = [:]
    @ObservationIgnored private var terminalBlockOrder: [Int] = []
    @ObservationIgnored private var source: any ChatEventSource
    @ObservationIgnored private var sourceIdentity: String?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private let projector: ChatTranscriptProjector
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let maxWindowCount: Int
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pendingCounter = 0
    @ObservationIgnored private var isFlushingQueue = false
    /// True once a queued send has been flushed in the current idle
    /// window; cleared when the agent next leaves idle. Ensures queued
    /// prompts are delivered ONE per turn (the agent only flips back to
    /// .working a round-trip after the first inject, so an ungated loop
    /// would dump them all into a still-idle terminal at once).
    @ObservationIgnored private var didFlushThisIdleWindow = false

    /// Creates a conversation store.
    ///
    /// - Parameters:
    ///   - descriptor: The session to show.
    ///   - source: The conversation data seam.
    ///   - sourceIdentity: Optional producer identity used to accept version
    ///     resets only when the underlying source changes.
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
        sourceIdentity: String? = nil,
        lastReadSeq: Int? = nil,
        projector: ChatTranscriptProjector = ChatTranscriptProjector(),
        pageSize: Int = 100,
        maxWindowCount: Int = 600,
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping @Sendable (Duration) async -> Void = { try? await ContinuousClock().sleep(for: $0) }
    ) {
        self.descriptor = descriptor
        self.agentState = descriptor.state
        self.source = source
        self.sourceIdentity = sourceIdentity
        self.projector = projector
        self.pageSize = pageSize
        self.maxWindowCount = maxWindowCount
        self.now = now
        self.idleSleep = idleSleep
        self.lastReadSeqAtActivation = lastReadSeq
    }

    @ObservationIgnored private let lastReadSeqAtActivation: Int?
    /// Cancellable reconnect-backoff sleep; injectable for deterministic
    /// tests.
    @ObservationIgnored private let idleSleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var backoffWakeContinuation: AsyncStream<Void>.Continuation?

    /// Follows the live event stream until cancelled, loading history
    /// inside each subscription so no event falls into a fetch/subscribe
    /// gap. Run this from the owning view's `.task` modifier.
    ///
    /// If the stream ends while the task is still active (connection drop),
    /// the store marks itself disconnected and resubscribes; the event
    /// source owns backoff policy.
    public func run() async {
        var backoff: Duration = .zero
        while !Task.isCancelled {
            let runGeneration = sourceGeneration
            // Subscribe FIRST: events emitted while the history fetch is in
            // flight buffer in the stream and replay after the merge (the
            // window dedups by message id), instead of being dropped.
            let stream = await source.events(sessionID: descriptor.id)
            guard runGeneration == sourceGeneration else { continue }
            isConnected = true
            let hadHistory = hasLoadedInitialHistory
            await loadInitialHistoryIfNeeded(expectedGeneration: runGeneration)
            guard runGeneration == sourceGeneration else { continue }
            if hadHistory {
                // Reconnect: merge whatever the window missed while down.
                await resyncTail(expectedGeneration: runGeneration)
                guard runGeneration == sourceGeneration else { continue }
            }
            let streamStartedAt = now()
            for await event in stream {
                guard runGeneration == sourceGeneration else { break }
                apply(event)
                // If the initial history fetch failed (e.g. the Mac couldn't
                // read the transcript yet — a title-detected agent adopted
                // before its jsonl was written), a live frame means it is
                // readable now. Retry so the error banner clears and full
                // context loads instead of parking on the failure. No-ops once
                // loaded; only re-runs while the fetch still throws.
                if !hasLoadedInitialHistory {
                    await loadInitialHistoryIfNeeded(expectedGeneration: runGeneration)
                    guard runGeneration == sourceGeneration else { break }
                }
                // Flush queued sends inline once the agent goes idle —
                // structured here in the async run loop rather than a
                // detached Task spawned from the synchronous apply().
                if case .idle = agentState {
                    await flushQueuedSends()
                }
            }
            guard runGeneration == sourceGeneration else { continue }
            isConnected = false
            guard !Task.isCancelled else { return }
            // Back off before resubscribing unless the stream was healthy
            // (survived a while): a flapping connection dies in well under
            // five seconds, while an idle session's stream can legitimately
            // deliver nothing for hours — liveness, not traffic, is the
            // health signal. Cancellable sleep.
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await waitForBackoffOrSourceReplacement(backoff)
            }
        }
    }

    private func waitForBackoffOrSourceReplacement(_ backoff: Duration) async {
        let idleSleep = idleSleep
        let wakeStream = AsyncStream<Void> { continuation in
            wakeBackoff()
            backoffWakeContinuation = continuation
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await idleSleep(backoff)
            }
            group.addTask {
                for await _ in wakeStream { break }
            }
            await group.next()
            wakeBackoff()
            group.cancelAll()
        }
    }

    private func wakeBackoff() {
        backoffWakeContinuation?.yield(())
        backoffWakeContinuation?.finish()
        backoffWakeContinuation = nil
    }

    /// Fetches one older page and prepends it to the window.
    public func loadOlder() async {
        guard hasMoreHistory, !isLoadingOlder else { return }
        // An empty window with hasMoreHistory still true would fetch the newest
        // page (beforeSeq nil) and prepend it as if it were older history.
        // Unreachable today (reset clears hasMoreHistory before emptying), but
        // guard against a future path leaving the window empty.
        guard let oldestSeq = messages.first?.seq else {
            hasMoreHistory = false
            return
        }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let generation = sourceGeneration
        do {
            let page = try await source.history(
                sessionID: descriptor.id,
                beforeSeq: oldestSeq,
                limit: pageSize
            )
            guard generation == sourceGeneration else { return }
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
            guard generation == sourceGeneration else { return }
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
        // While the agent is working, a paste-plus-submit lands the text in
        // Claude Code's input box but the running task swallows the submit
        // Enter, stranding it. Queue instead and flush when the agent next
        // goes idle, so the message is delivered cleanly in turn order.
        let queueWhileBusy: Bool
        if case .working = agentState { queueWhileBusy = true } else { queueWhileBusy = false }
        let item = ChatPendingOutbound(
            id: "local-\(pendingCounter)",
            text: trimmed,
            attachments: attachments,
            createdAt: now(),
            delivery: queueWhileBusy ? .queued : .sending
        )
        latestOutboundFocusRowID = ChatTranscriptRow.pendingOutboundRowID(for: item.id)
        pending.append(item)
        reproject()
        guard !queueWhileBusy else { return }
        await deliver(item)
    }

    /// Sends one pending row through the source, updating its delivery
    /// state. Shared by immediate sends, queued flushes, and retries.
    private func deliver(_ item: ChatPendingOutbound) async {
        updatePending(id: item.id, delivery: .sending)
        do {
            try await source.send(text: item.text, attachments: item.attachments, sessionID: descriptor.id)
            updatePending(id: item.id, delivery: .delivered)
            lastErrorDescription = nil
        } catch {
            updatePending(id: item.id, delivery: .failed(error.localizedDescription))
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Flushes queued sends once the agent is idle, in submission order.
    /// Re-entrancy is guarded so overlapping idle transitions don't
    /// double-send.
    private func flushQueuedSends() async {
        guard !isFlushingQueue, !didFlushThisIdleWindow else { return }
        guard case .idle = agentState else { return }
        guard let next = pending.first(where: { $0.delivery == .queued }) else { return }
        isFlushingQueue = true
        didFlushThisIdleWindow = true
        defer { isFlushingQueue = false }
        // Exactly one per idle window: delivering it makes the agent work,
        // and the next working->idle transition re-arms the flush for the
        // following queued prompt, preserving turn order.
        await deliver(next)
    }

    /// Retries a failed pending send.
    ///
    /// - Parameter pendingID: The pending row to retry.
    public func retry(pendingID: String) async {
        guard let index = pending.firstIndex(where: { $0.id == pendingID }),
              case .failed = pending[index].delivery else { return }
        // Same queue-while-busy rule as send(): delivering into a working agent
        // strands the submit Enter. Re-queue and let flushQueuedSends deliver it
        // in turn order on the next idle transition.
        if case .working = agentState {
            updatePending(id: pendingID, delivery: .queued)
            return
        }
        await deliver(pending[index])
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

    private func loadInitialHistoryIfNeeded(expectedGeneration: Int? = nil) async {
        guard !hasLoadedInitialHistory else { return }
        let generation = expectedGeneration ?? sourceGeneration
        // A fresh newest-page load re-anchors paging; truncated-at-head is only
        // re-discovered if a later loadOlder hits the Mac cache head.
        historyTruncatedAtHead = false
        do {
            let page = try await source.history(
                sessionID: descriptor.id,
                beforeSeq: nil,
                limit: pageSize
            )
            guard generation == sourceGeneration else { return }
            if descriptor.kind == .terminal {
                seedTerminalBlocks(page.terminalBlocks ?? [])
                // Block paging isn't implemented yet, so never advertise more
                // history for a terminal (loadOlder can't page blocks and
                // would otherwise flip the UI into a wrong truncated state).
                hasMoreHistory = false
            } else {
                messages = page.messages
                if let lastRead = lastReadSeqAtActivation,
                   let firstUnread = page.messages.first(where: { $0.seq > lastRead }) {
                    firstUnreadSeq = firstUnread.seq
                }
                hasMoreHistory = page.hasMore
            }
            hasLoadedInitialHistory = true
            initialLoadFailed = false
            lastErrorDescription = nil
            reproject()
        } catch {
            guard generation == sourceGeneration else { return }
            // Only flag failure while the initial load is still pending: a
            // racing duplicate fetch (retry button vs reconnect) that fails
            // AFTER another succeeded must not strand a dead error UI.
            if !hasLoadedInitialHistory {
                initialLoadFailed = true
            }
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Clears the transient error banner (user dismissal or auto-expiry;
    /// the owning view drives timing through a cancellable task).
    public func dismissError() {
        lastErrorDescription = nil
    }

    /// Retries a failed initial history load (user-invoked).
    public func retryInitialLoad() async {
        guard !hasLoadedInitialHistory else { return }
        initialLoadFailed = false
        await loadInitialHistoryIfNeeded()
    }

    /// Reconciles a fresh session-list descriptor into this conversation cache.
    public func applyDescriptorSnapshot(
        _ descriptor: ChatSessionDescriptor,
        allowsVersionReset: Bool = false
    ) {
        guard descriptor.id == self.descriptor.id else { return }
        let isUnversioned = descriptor.version == 0 && self.descriptor.version == 0
        let isNewer = descriptor.version > self.descriptor.version
        let isProducerReset = allowsVersionReset
        guard isUnversioned || isNewer || isProducerReset else { return }
        self.descriptor = descriptor
        agentState = descriptor.state
        if case .idle = descriptor.state {
            Task { await flushQueuedSends() }
        } else {
            didFlushThisIdleWindow = false
        }
    }

    /// Rebinds this conversation to the current Mac transport after reconnect.
    public func replaceSource(
        _ source: any ChatEventSource,
        descriptor: ChatSessionDescriptor,
        sourceIdentity: String? = nil
    ) {
        let didChangeSource = sourceIdentity == nil || sourceIdentity != self.sourceIdentity
        self.source = source
        self.sourceIdentity = sourceIdentity
        if didChangeSource {
            sourceGeneration += 1
            resetTranscriptAnchorForSourceReplacement()
        }
        wakeBackoff()
        applyDescriptorSnapshot(descriptor, allowsVersionReset: didChangeSource)
    }

    /// Clears transcript state that is anchored to the prior event producer.
    private func resetTranscriptAnchorForSourceReplacement() {
        messages = []
        streamingMessage = nil
        firstUnreadSeq = nil
        terminalBlocks = [:]
        terminalBlockOrder = []
        pending.removeAll { $0.delivery == .delivered }
        hasMoreHistory = false
        historyTruncatedAtHead = false
        initialLoadFailed = false
        hasLoadedInitialHistory = false
        isLoadingOlder = false
        reproject()
    }

    /// After a stream drop, fetches the newest page and merges anything the
    /// window missed while disconnected.
    private func resyncTail(expectedGeneration: Int? = nil) async {
        let generation = expectedGeneration ?? sourceGeneration
        // Re-deriving the window from the newest page resets paging; a later
        // loadOlder re-discovers truncated-at-head if it still applies.
        historyTruncatedAtHead = false
        do {
            let page = try await source.history(
                sessionID: descriptor.id,
                beforeSeq: nil,
                limit: pageSize
            )
            guard generation == sourceGeneration else { return }
            if descriptor.kind == .terminal {
                // Blocks are whole-value and keyed by id, so re-seeding from
                // the authoritative page is idempotent.
                seedTerminalBlocks(page.terminalBlocks ?? [])
                hasMoreHistory = false
                lastErrorDescription = nil
                reproject()
                return
            }
            guard let newestKnown = messages.last?.seq else {
                reconcilePending(against: page.messages)
                messages = page.messages
                hasMoreHistory = page.hasMore
                // A successful resync clears any stale failure banner from a
                // prior history/send error, including on this empty-window
                // recovery path (e.g. after a .reset emptied the window).
                lastErrorDescription = nil
                reproject()
                return
            }
            let missed = page.messages.filter { $0.seq > newestKnown }
            let pageIDs = Set(page.messages.map(\.id))
            let windowIDs = Set(messages.map(\.id))
            let pageHasUnknownContent = page.messages.contains { !windowIDs.contains($0.id) }
            if missed.isEmpty, pageHasUnknownContent {
                // The page carries content at-or-below the window tail that
                // the window doesn't have. Reachable when a post-reset live
                // append beat this resync (the window holds one fresh
                // message; the page is the authoritative rewritten
                // history). Adopt the page plus any window suffix beyond
                // its end.
                let pageEndSeq = page.messages.last?.seq ?? -1
                let suffix = messages.filter { !pageIDs.contains($0.id) && $0.seq > pageEndSeq }
                reconcilePending(against: page.messages)
                messages = page.messages + suffix
                hasMoreHistory = page.hasMore
                reproject()
            } else if missed.count == page.messages.count, page.hasMore, !missed.isEmpty {
                // The entire newest page is beyond the window tail: the
                // disconnect outlasted a full page and the gap can never be
                // filled by tail-append. Re-anchor the window on the page.
                reconcilePending(against: page.messages)
                messages = page.messages
                hasMoreHistory = true
                reproject()
            } else if !missed.isEmpty {
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
            guard generation == sourceGeneration else { return }
            lastErrorDescription = error.localizedDescription
        }
    }

    private func apply(_ event: ChatSessionEvent) {
        switch event {
        case .appended(let newMessages):
            reconcilePending(against: newMessages)
            // The authoritative agent prose for the in-flight turn just landed:
            // drop the live preview so the committed message takes over with no
            // duplicate, even if the host's explicit clear is delayed or lost.
            if streamingMessage != nil,
               newMessages.contains(where: { $0.role == .agent && Self.isProse($0) }) {
                streamingMessage = nil
            }
            // A live append whose seq regresses below the window tail means
            // the transcript was truncated/replaced and the tailer reset;
            // appending would corrupt window ordering. Re-anchor instead.
            if let tail = messages.last?.seq,
               let incoming = newMessages.first?.seq,
               incoming <= tail,
               !newMessages.contains(where: { knownWindowIDs.contains($0.id) }) {
                messages = newMessages
                hasMoreHistory = true
                reproject()
            } else {
                appendToWindow(newMessages)
            }
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
            if case .idle = state {} else { didFlushThisIdleWindow = false }
        case .descriptorChanged(let descriptor):
            self.descriptor = descriptor
            agentState = descriptor.state
            if case .idle = descriptor.state {} else { didFlushThisIdleWindow = false }
        case .terminalBlocks(let blocks):
            // Upsert by id: a new id appends to the order; an existing id
            // replaces in place (output grew / command finished). Whole-block
            // values make replayed blocks on reconnect idempotent.
            for block in blocks {
                if terminalBlocks[block.id] == nil { terminalBlockOrder.append(block.id) }
                terminalBlocks[block.id] = block
            }
            // A typed command echoes back as its own command block; clear the
            // optimistic pending row it came from so it doesn't linger or leak.
            reconcileTerminalPending(against: blocks)
            reproject()
        case .streamingProse(let message):
            // The preview is a whole-value replace; an agent session only. A
            // terminal session has no agent prose, so ignore it there.
            guard descriptor.kind != .terminal else { break }
            let next = message.flatMap { Self.isProse($0) ? $0 : nil }
            guard next != streamingMessage else { break }
            streamingMessage = next
            reproject()
        case .reset:
            // The transcript was truncated/replaced on the Mac (tailer
            // re-read from scratch). The window's seq space is void; clear
            // and re-anchor from fresh history. Delivered pendings die with
            // the old transcript (their echo is gone), but failed rows keep
            // their retry and in-flight sends may still land in the new
            // transcript and reconcile normally.
            messages = []
            // The preview belongs to the old seq space; drop it on re-anchor.
            streamingMessage = nil
            // Terminal blocks must clear here too: the terminal reproject()
            // does not consult `messages`, so without this the synchronous
            // reproject below would re-render stale blocks (and they'd persist
            // permanently if the resync history fetch fails).
            terminalBlocks = [:]
            terminalBlockOrder = []
            pending.removeAll { $0.delivery == .delivered }
            hasMoreHistory = false
            // The new transcript re-anchors paging from scratch; a stale
            // truncated-at-head flag would render the "earlier history is on
            // your Mac" cell above a fresh short conversation. resyncTail
            // re-derives the real paging state.
            historyTruncatedAtHead = false
            reproject()
            Task { await resyncTail() }
        case .unknown:
            break
        }
    }

    private var knownWindowIDs: Set<String> {
        Set(messages.map(\.id))
    }

    private func appendToWindow(_ newMessages: [ChatMessage]) {
        // Dedup by id against the FULL window: a live event can replay
        // content the history fetch in the same subscription cycle already
        // merged, and a single tailer drain can exceed any fixed suffix.
        let knownIDs = Set(messages.map(\.id))
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
        var maxReconciledCounter: Int?
        for message in newMessages where message.role == .user {
            let index: Int?
            switch message.kind {
            case .prose(let prose):
                let echoed = prose.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Two passes: an exact-text match anywhere beats shape
                // heuristics on an older pending, so "/compact"'s own echo
                // can't be eaten by an attachment-only pending's path rule.
                index = pending.firstIndex { item in
                    guard item.isReconcilable else { return false }
                    return item.text == echoed
                } ?? pending.firstIndex { item in
                    guard item.isReconcilable else { return false }
                    if item.text.isEmpty {
                        // Attachment-only send: the Mac pastes the staged
                        // clipboard-image path, so the echo is a lone
                        // pasteboard path line (never a user "/command").
                        return !echoed.contains("\n")
                            && echoed.hasPrefix("/")
                            && echoed.contains("clipboard-")
                    }
                    // Attachments are pasted as file paths ahead of the
                    // prompt, so a text+image echo is "<path> <text>".
                    if item.attachmentCount > 0,
                       echoed.hasPrefix("/"),
                       echoed.hasSuffix(" " + item.text) {
                        return true
                    }
                    // The transcript copy may be budget-truncated ("…"
                    // suffix); match on the echoed prefix so long prompts
                    // still reconcile.
                    if echoed.hasSuffix("…"), echoed.count > 64,
                       item.text.hasPrefix(echoed.dropLast()) {
                        return true
                    }
                    // If the terminal prompt still held a tiny stale draft
                    // when the mobile chat send was pasted, Claude can echo
                    // "<stale><prompt>". Reconcile the optimistic row so the
                    // UI does not show the clean pending prompt as a second
                    // sent bubble after the transcript line.
                    if item.attachmentCount == 0,
                       Self.echoedTextHasShortStalePrefix(echoed, pendingText: item.text) {
                        return true
                    }
                    // Bracketed sends can echo as Claude Code's paste
                    // placeholder rather than the literal text; multi-line
                    // and long single-line prompts both collapse to it.
                    if Self.isPastePlaceholder(echoed) {
                        return item.text.contains("\n") || item.text.count > 256
                    }
                    return false
                }
            case .attachment:
                // Fixture/demo path: attachment echoes arrive typed.
                index = pending.firstIndex { item in
                    item.isReconcilable && item.text.isEmpty
                }
            default:
                index = nil
            }
            if let index {
                let removed = pending.remove(at: index)
                let removedRowID = ChatTranscriptRow.pendingOutboundRowID(for: removed.id)
                if latestOutboundFocusRowID == removedRowID {
                    latestOutboundFocusRowID = ChatTranscriptRow.messageRowID(for: message.id)
                }
                if let counter = Self.pendingCounter(removed.id) {
                    maxReconciledCounter = max(maxReconciledCounter ?? counter, counter)
                }
            }
        }
        // Evict any older plain-text `.delivered` pending that never matched:
        // the agent echoes plain-text sends in submission order, so once a
        // LATER send's echo lands, an earlier delivered-but-unmatched text
        // row's echo has already passed and will never reconcile — it would
        // otherwise linger as a permanent duplicate next to the real
        // transcript line. Attachment-bearing and attachment-only pendings are
        // EXCLUDED: their pasted-path echo can arrive out of order relative to
        // a following text command (see slashCommandEchoDoesNotEatAttachment),
        // so they keep their own reconcile lifecycle. Only `.delivered` rows
        // (RPC-confirmed) are swept; sending/queued/failed keep their state.
        if let maxReconciledCounter {
            pending.removeAll { item in
                guard item.delivery == .delivered,
                      item.attachmentCount == 0,
                      !item.text.isEmpty,
                      let counter = Self.pendingCounter(item.id),
                      counter < maxReconciledCounter else { return false }
                return true
            }
        }
    }

    /// Parses the monotonic counter from a pending row id (`local-<n>`), used
    /// to order sends for stale-delivered eviction.
    static func pendingCounter(_ id: String) -> Int? {
        guard let dash = id.lastIndex(of: "-") else { return nil }
        return Int(id[id.index(after: dash)...])
    }

    /// Whether an echoed user line is Claude Code's bracketed-paste
    /// placeholder ("[Pasted text #1 +12 lines]").
    static func isPastePlaceholder(_ text: String) -> Bool {
        text.wholeMatch(of: /\[Pasted text #\d+( \+\d+ lines)?\]/) != nil
    }

    /// Matches the prompt when Claude echoes it with a short, non-spaced
    /// prefix left behind in the terminal line editor.
    static func echoedTextHasShortStalePrefix(_ echoed: String, pendingText: String) -> Bool {
        let pending = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty,
              echoed != pending,
              echoed.hasSuffix(pending) else { return false }
        let prefix = echoed.dropLast(pending.count)
        guard !prefix.isEmpty, prefix.count <= 8 else { return false }
        return !prefix.contains { character in
            character.isWhitespace || character.isNewline
        }
    }

    private func updatePending(id: String, delivery: ChatDeliveryState) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].delivery = delivery
        reproject()
    }

    /// Removes optimistic pending rows whose command echoed back as a
    /// terminal command-block (the terminal analogue of `reconcilePending`).
    /// Failed pendings keep their retry row (`isReconcilable` is false).
    private func reconcileTerminalPending(against blocks: [TerminalCommandBlock]) {
        guard !pending.isEmpty else { return }
        for block in blocks {
            let command = block.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            if let index = pending.firstIndex(where: {
                $0.isReconcilable
                    && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == command
            }) {
                let removed = pending.remove(at: index)
                let removedRowID = ChatTranscriptRow.pendingOutboundRowID(for: removed.id)
                if latestOutboundFocusRowID == removedRowID {
                    latestOutboundFocusRowID = ChatTranscriptRow.terminalCommandRowID(for: block.id)
                }
            }
        }
    }

    /// Replaces the terminal block window from a history page (oldest first).
    private func seedTerminalBlocks(_ blocks: [TerminalCommandBlock]) {
        terminalBlocks = [:]
        terminalBlockOrder = []
        for block in blocks {
            if terminalBlocks[block.id] == nil { terminalBlockOrder.append(block.id) }
            terminalBlocks[block.id] = block
        }
    }

    private func reproject() {
        // A terminal session is a flat ordered command log, not a grouped
        // conversation, so it bypasses the bubble-grouping projector. The
        // agent branch is unchanged.
        if descriptor.kind == .terminal {
            // Include optimistic sends so the user sees their command (and any
            // failure/retry) until the shell echoes it back as a command
            // block; otherwise a terminal send would be invisible.
            rows = terminalBlockOrder.compactMap { terminalBlocks[$0] }
                .map(ChatTranscriptRow.terminalCommand)
                + pending.map(ChatTranscriptRow.pendingOutbound)
            return
        }
        // The live preview renders as a trailing agent bubble after the
        // committed window. Appending it to the projector input lets it group
        // with adjacent agent prose exactly like a real message; it carries no
        // window identity (never paged, deduped, or reconciled by id).
        let projected: [ChatMessage]
        if let streamingMessage, !messages.contains(where: { $0.id == streamingMessage.id }) {
            projected = messages + [streamingMessage]
        } else {
            projected = messages
        }
        rows = projector.rows(
            messages: projected,
            pending: pending,
            firstUnreadSeq: firstUnreadSeq
        )
    }

    /// Whether a message is renderable agent/user prose (used to settle the
    /// live preview against the authoritative transcript line).
    private static func isProse(_ message: ChatMessage) -> Bool {
        if case .prose = message.kind { return true }
        return false
    }
}
