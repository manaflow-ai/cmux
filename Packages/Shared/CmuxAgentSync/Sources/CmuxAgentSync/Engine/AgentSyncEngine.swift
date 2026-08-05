public import CmuxAgentReplica
public import CmuxAgentWire
public import Foundation
public import Observation

private struct AgentPagingRequestKey: Hashable {
    let sessionID: AgentSessionID
    let anchor: GuiEntriesAnchor
    let cursor: JournalCursor?
}

/// Drives agent GUI replica stores over an abstract transport.
@MainActor
@Observable
public final class AgentSyncEngine {
    /// The session directory replica for the attached Mac.
    public let directory: SessionDirectoryReplica
    /// Observable connectivity state for the attached Mac.
    public let connectivity: AgentConnectivityState
    /// Open conversation replicas keyed by session id.
    public private(set) var conversations: [AgentSessionID: ConversationReplica]
    /// Engine-owned streaming previews keyed by session id.
    public private(set) var streamingTails: [AgentSessionID: AgentStreamingTail]
    /// Last `has_more_before` value reported for each open conversation.
    public private(set) var hasMoreBeforeBySession: [AgentSessionID: Bool]
    /// Last `has_more_after` value reported for each open conversation.
    public private(set) var hasMoreAfterBySession: [AgentSessionID: Bool]
    /// Last capability report returned per session.
    public private(set) var cachedCapabilities: [AgentSessionID: GuiCapabilitiesResult]
    /// Count of transport frames that could not be decoded as `gui.v1` frames.
    public private(set) var malformedFrameCount: Int

    @ObservationIgnored let transport: any AgentSyncTransport
    @ObservationIgnored private let syncClock: any SyncClock
    @ObservationIgnored let replicaClock: any ReplicaClock
    @ObservationIgnored private let ticketIDGenerator: any AgentSyncTicketIDGenerator
    @ObservationIgnored let jitter: any AgentSyncJitter
    @ObservationIgnored let encoder: JSONEncoder
    @ObservationIgnored let decoder: JSONDecoder
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var tailPullTasks: [AgentSessionID: Task<Void, Never>]
    @ObservationIgnored private var pagingTasks: [AgentPagingRequestKey: Task<GuiEntriesResult, any Error>]
    @ObservationIgnored private var pagingGenerationBySession: [AgentSessionID: UInt64]
    @ObservationIgnored private var conversationOwnerCounts: [AgentSessionID: Int]
    @ObservationIgnored private var retryAttempt: Int
    @ObservationIgnored private var resyncRequested: Bool
    @ObservationIgnored private var started: Bool
    @ObservationIgnored private var stopped: Bool
    @ObservationIgnored private var malformedFrameTimes: [Int64]

    /// Creates an agent sync engine.
    /// - Parameters:
    ///   - transport: The abstract transport to one attached Mac.
    ///   - syncClock: Clock used for retry and debounce timing.
    ///   - replicaClock: Clock passed into replica stores and local send tickets.
    ///   - ticketIDGenerator: Generator for client-minted send tickets.
    ///   - jitter: Retry jitter source.
    public init(
        transport: any AgentSyncTransport,
        syncClock: any SyncClock = RealSyncClock(),
        replicaClock: any ReplicaClock = AgentSyncReplicaClock(),
        ticketIDGenerator: any AgentSyncTicketIDGenerator = UUIDAgentSyncTicketIDGenerator(),
        jitter: any AgentSyncJitter = RandomAgentSyncJitter()
    ) {
        self.transport = transport
        self.syncClock = syncClock
        self.replicaClock = replicaClock
        self.ticketIDGenerator = ticketIDGenerator
        self.jitter = jitter
        directory = SessionDirectoryReplica()
        connectivity = AgentConnectivityState()
        conversations = [:]
        streamingTails = [:]
        hasMoreBeforeBySession = [:]
        hasMoreAfterBySession = [:]
        cachedCapabilities = [:]
        malformedFrameCount = 0
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        tailPullTasks = [:]
        pagingTasks = [:]
        pagingGenerationBySession = [:]
        conversationOwnerCounts = [:]
        retryAttempt = 0
        resyncRequested = false
        started = false
        stopped = false
        malformedFrameTimes = []
    }

    deinit {
        connectionTask?.cancel()
        frameTask?.cancel()
        retryTask?.cancel()
        resyncTask?.cancel()
        for (_, task) in tailPullTasks {
            task.cancel()
        }
        for (_, task) in pagingTasks {
            task.cancel()
        }
    }

    /// Starts connection-event observation and an initial reconciliation.
    ///
    /// Calling this method after ``stop()`` has no effect; engines are single-use.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.transport.connectionEvents {
                guard !Task.isCancelled else { return }
                self.handleConnectionEvent(event)
            }
        }
        triggerResync()
    }

    /// Permanently stops all engine-owned asynchronous work.
    ///
    /// A stopped engine cannot be restarted. Create a new engine for a replacement transport.
    public func stop() {
        stopped = true
        started = false
        connectivity.setPhase(.offline(reason: "stopped"))
        connectionTask?.cancel()
        connectionTask = nil
        frameTask?.cancel()
        frameTask = nil
        retryTask?.cancel()
        retryTask = nil
        resyncTask?.cancel()
        resyncTask = nil
        for (_, task) in tailPullTasks {
            task.cancel()
        }
        tailPullTasks.removeAll()
        for (_, task) in pagingTasks {
            task.cancel()
        }
        pagingTasks.removeAll()
    }

    /// Opens or retains the conversation replica for a session.
    ///
    /// Each call claims one owner. Balance it with ``closeConversation(sessionID:)``;
    /// the replica remains live until its final owner closes it.
    /// - Parameter sessionID: The session to open.
    /// - Returns: The conversation replica for the session.
    public func openConversation(sessionID: AgentSessionID) -> ConversationReplica {
        conversationOwnerCounts[sessionID, default: 0] += 1
        return conversationForUse(sessionID: sessionID)
    }
    /// Releases one conversation owner and drops its live subscription after the last release.
    /// - Parameter sessionID: The session to close.
    public func closeConversation(sessionID: AgentSessionID) {
        guard let ownerCount = conversationOwnerCounts[sessionID] else { return }
        if ownerCount > 1 {
            conversationOwnerCounts[sessionID] = ownerCount - 1
            return
        }
        conversationOwnerCounts[sessionID] = nil
        guard conversations.removeValue(forKey: sessionID) != nil else { return }
        streamingTails[sessionID] = nil
        hasMoreBeforeBySession[sessionID] = nil
        hasMoreAfterBySession[sessionID] = nil
        cachedCapabilities[sessionID] = nil
        tailPullTasks.removeValue(forKey: sessionID)?.cancel()
        cancelPagingRequests(sessionID: sessionID)
        if started {
            triggerResync()
        }
    }

    /// Queues a user send ticket and submits it immediately when connected.
    /// - Parameters:
    ///   - sessionID: The destination session.
    ///   - text: User-authored text.
    /// - Returns: The minted send-ticket identifier.
    @discardableResult
    public func send(sessionID: AgentSessionID, text: String) -> UUID {
        let conversation = conversationForUse(sessionID: sessionID)
        let ticketID = ticketIDGenerator.nextTicketID()
        let ticket = SendTicket(
            id: ticketID,
            sessionID: sessionID,
            text: text,
            attachmentCount: 0,
            state: .queuedLocal,
            createdAt: replicaClock.tick()
        )
        conversation.apply(.sendTicketChanged(ticket), origin: .live)
        if connectivity.phase == .connected {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.submitQueuedTicket(ticket, origin: .live)
                } catch {
                    self.scheduleRetry(reason: Self.errorDescription(error))
                }
            }
        }
        return ticketID
    }

    /// Requeues a failed send using its original idempotency key.
    /// - Parameters:
    ///   - sessionID: The ticket's conversation.
    ///   - ticketID: The failed ticket identifier.
    /// - Returns: Whether a matching failed ticket was requeued.
    @discardableResult
    public func retrySend(sessionID: AgentSessionID, ticketID: UUID) -> Bool {
        guard let conversation = conversations[sessionID],
              let failedTicket = conversation.sendTickets.first(where: { $0.id == ticketID }),
              case .failed = failedTicket.state
        else { return false }
        let queuedTicket = SendTicket(
            id: failedTicket.id,
            sessionID: failedTicket.sessionID,
            text: failedTicket.text,
            attachmentCount: failedTicket.attachmentCount,
            state: .queuedLocal,
            createdAt: failedTicket.createdAt
        )
        conversation.apply(.sendTicketChanged(queuedTicket), origin: .live)
        if connectivity.phase == .connected {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.submitQueuedTicket(queuedTicket, origin: .live)
                } catch {
                    self.scheduleRetry(reason: Self.errorDescription(error))
                }
            }
        }
        return true
    }
    private func conversationForUse(sessionID: AgentSessionID) -> ConversationReplica {
        if let conversation = conversations[sessionID] {
            return conversation
        }
        conversationOwnerCounts[sessionID] = max(conversationOwnerCounts[sessionID] ?? 0, 1)
        let conversation = ConversationReplica(
            sessionID: sessionID,
            clock: replicaClock
        )
        conversations[sessionID] = conversation
        if started {
            triggerResync()
        }
        return conversation
    }

    /// Interrupts a connected session without offline queueing.
    /// - Parameters:
    ///   - sessionID: The session to interrupt.
    ///   - hard: Whether to request a hard interrupt.
    /// - Throws: ``AgentSyncError/offline`` when the engine is not connected.
    public func interrupt(sessionID: AgentSessionID, hard: Bool) async throws {
        try ensureConnected()
        let params = GuiInterruptParams(sessionID: sessionID, hard: hard)
        let data = try await request(method: GuiWireMethod.interrupt, params: params)
        _ = try decode(GuiInterruptResult.self, from: data)
    }

    /// Answers a connected pending ask without offline queueing.
    /// - Parameters:
    ///   - sessionID: The session that owns the ask.
    ///   - askID: The ask identifier.
    ///   - choice: The selected zero-based choice index.
    /// - Throws: ``AgentSyncError/offline`` when the engine is not connected.
    public func answer(sessionID: AgentSessionID, askID: String, choice: Int) async throws {
        try ensureConnected()
        let params = GuiAnswerParams(sessionID: sessionID, askID: askID, choiceIndex: choice)
        let data = try await request(method: GuiWireMethod.answer, params: params)
        _ = try decode(GuiAnswerResult.self, from: data)
    }

    /// Loads the next older page for an open conversation.
    /// - Parameter sessionID: The session whose older page should load.
    /// - Throws: ``AgentSyncError/conversationNotOpen`` when the conversation is not open.
    public func loadOlder(sessionID: AgentSessionID) async throws {
        guard let conversation = conversations[sessionID] else {
            throw AgentSyncError.conversationNotOpen
        }
        guard hasMoreBeforeBySession[sessionID] ?? conversation.hasMoreBefore else { return }
        let generation = pagingGenerationBySession[sessionID, default: 0]
        let result: GuiEntriesResult
        if let cursor = conversation.startCursor {
            result = try await coalescedPage(
                sessionID: sessionID,
                journalID: conversation.journalID,
                anchor: .before,
                cursor: cursor
            )
        } else {
            result = try await entries(
                sessionID: sessionID,
                journalID: conversation.journalID,
                beforeSeq: conversation.loadedRanges.map(\.lowerBound).min(),
                afterSeq: nil,
                limit: 50
            )
        }
        guard pagingGenerationBySession[sessionID, default: 0] == generation else { return }
        merge(result, into: conversation, retaining: .oldest)
    }

    /// Loads the next newer page for an open conversation.
    /// - Parameter sessionID: The session whose newer page should load.
    public func loadNewer(sessionID: AgentSessionID) async throws {
        guard let conversation = conversations[sessionID] else {
            throw AgentSyncError.conversationNotOpen
        }
        guard conversation.hasMoreAfter else { return }
        let generation = pagingGenerationBySession[sessionID, default: 0]
        let result: GuiEntriesResult
        if let cursor = conversation.endCursor {
            result = try await coalescedPage(
                sessionID: sessionID,
                journalID: conversation.journalID,
                anchor: .after,
                cursor: cursor
            )
        } else {
            result = try await entries(
                sessionID: sessionID,
                journalID: conversation.journalID,
                beforeSeq: nil,
                afterSeq: conversation.loadedRanges.map(\.upperBound).max(),
                limit: 50
            )
        }
        guard pagingGenerationBySession[sessionID, default: 0] == generation else { return }
        merge(result, into: conversation, retaining: .newest)
    }

    /// Replaces the loaded window with the first journal page.
    /// - Parameter sessionID: The session to jump to the beginning of.
    public func jumpToHead(sessionID: AgentSessionID) async throws {
        guard let conversation = conversations[sessionID] else {
            throw AgentSyncError.conversationNotOpen
        }
        let generation = beginNewPagingGeneration(sessionID: sessionID)
        let result = try await coalescedPage(
            sessionID: sessionID,
            journalID: conversation.journalID,
            anchor: .head,
            cursor: nil
        )
        guard pagingGenerationBySession[sessionID] == generation else { return }
        merge(result, into: conversation, retaining: .oldest, replacingWindow: true)
        guard result.requiresPagingRestart else { return }

        // A stale journal expectation resolves to the authoritative tail so
        // the client can adopt the replacement journal. Preserve the user's
        // semantic request by retrying head once with that new journal.
        let retry = try await coalescedPage(
            sessionID: sessionID,
            journalID: conversation.journalID,
            anchor: .head,
            cursor: nil
        )
        guard pagingGenerationBySession[sessionID] == generation else { return }
        merge(retry, into: conversation, retaining: .oldest, replacingWindow: true)
    }

    /// Replaces the loaded window with the current journal tail page.
    /// - Parameter sessionID: The session to jump to the end of.
    public func jumpToTail(sessionID: AgentSessionID) async throws {
        guard let conversation = conversations[sessionID] else {
            throw AgentSyncError.conversationNotOpen
        }
        let generation = beginNewPagingGeneration(sessionID: sessionID)
        let result = try await cursorEntries(
            sessionID: sessionID,
            journalID: conversation.journalID,
            anchor: .tail,
            cursor: nil,
            limit: 50
        )
        guard pagingGenerationBySession[sessionID] == generation else { return }
        merge(result, into: conversation, retaining: .newest, replacingWindow: true)
    }

    private func coalescedPage(
        sessionID: AgentSessionID,
        journalID: JournalID?,
        anchor: GuiEntriesAnchor,
        cursor: JournalCursor?
    ) async throws -> GuiEntriesResult {
        let key = AgentPagingRequestKey(sessionID: sessionID, anchor: anchor, cursor: cursor)
        if let task = pagingTasks[key] {
            return try await task.value
        }
        let task = Task<GuiEntriesResult, any Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.cursorEntries(
                sessionID: sessionID,
                journalID: journalID,
                anchor: anchor,
                cursor: cursor,
                limit: 50
            )
        }
        pagingTasks[key] = task
        defer { pagingTasks[key] = nil }
        return try await task.value
    }

    @discardableResult
    private func beginNewPagingGeneration(sessionID: AgentSessionID) -> UInt64 {
        cancelPagingRequests(sessionID: sessionID)
        let generation = pagingGenerationBySession[sessionID, default: 0] &+ 1
        pagingGenerationBySession[sessionID] = generation
        return generation
    }

    private func cancelPagingRequests(sessionID: AgentSessionID) {
        let keys = pagingTasks.keys.filter { $0.sessionID == sessionID }
        for key in keys {
            pagingTasks.removeValue(forKey: key)?.cancel()
        }
    }

    /// Fetches and caches a session capability report.
    /// - Parameter sessionID: The session to inspect.
    /// - Returns: The wire capability report.
    public func capabilities(sessionID: AgentSessionID) async throws -> GuiCapabilitiesResult {
        let data = try await request(
            method: GuiWireMethod.capabilities,
            params: GuiCapabilitiesParams(sessionID: sessionID)
        )
        let result = try decode(GuiCapabilitiesResult.self, from: data)
        cachedCapabilities[sessionID] = result
        return result
    }

    /// Triggers an immediate reconnect/resync after foregrounding.
    public func noteAppForegrounded() {
        triggerResync()
    }

    /// Triggers an immediate reconnect/resync after a network-path change.
    public func noteNetworkPathChanged() {
        triggerResync()
    }

    private func handleConnectionEvent(_ event: AgentSyncConnectionEvent) {
        switch event {
        case .up:
            triggerResync()
        case .down(let reason):
            connectivity.setPhase(.offline(reason: reason))
            frameTask?.cancel()
            frameTask = nil
        case .reset:
            connectivity.setPhase(.offline(reason: "reset"))
            frameTask?.cancel()
            frameTask = nil
            triggerResync()
        }
    }

    func triggerResync() {
        guard started, !stopped else { return }
        retryTask?.cancel()
        retryTask = nil
        if resyncTask != nil {
            resyncRequested = true
            return
        }
        resyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runResyncUntilSettled()
        }
    }

    private func scheduleRetry(reason: String) {
        guard !stopped else { return }
        connectivity.recordFailure(reason: reason)
        connectivity.setPhase(.offline(reason: reason))
        retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delay = self.retryDelayMilliseconds(attempt: self.retryAttempt)
            self.connectivity.setPhase(.connecting(backoffMilliseconds: delay))
            await self.syncClock.sleep(milliseconds: delay)
            guard !Task.isCancelled else { return }
            self.triggerResync()
        }
    }

    private func runResyncUntilSettled() async {
        repeat {
            resyncRequested = false
            do {
                try await runResync()
                retryAttempt = 0
            } catch {
                resyncTask = nil
                scheduleRetry(reason: Self.errorDescription(error))
                return
            }
        } while resyncRequested && !Task.isCancelled
        resyncTask = nil
    }

    private func runResync() async throws {
        connectivity.setPhase(.updating)
        let hello = try await requestHello()
        applyEpochChangeIfNeeded(to: hello.epoch)

        let topics = desiredTopics()
        let stream = try await transport.subscribe(topics: topics)
        startFrameTask(stream: stream)

        let sessions = try await requestSessions()
        applyEpochChangeIfNeeded(to: sessions.epoch)
        directory.replaceAll(sessions.sessions, epoch: sessions.epoch)

        for sessionID in conversations.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            try await pullTail(sessionID: sessionID)
        }
        try await flushQueuedTickets()
        connectivity.recordSuccessfulSync()
        connectivity.setPhase(.connected)
    }

    private func applyEpochChangeIfNeeded(to epoch: ReplicaEpoch) {
        guard directory.epoch != epoch else { return }
        directory.handleEpochChange(to: epoch)
        for conversation in conversations.values {
            conversation.handleEpochChange(to: epoch)
            streamingTails[conversation.sessionID] = nil
        }
    }

    private func startFrameTask(stream: AsyncStream<AgentSyncFrame>) {
        frameTask?.cancel()
        frameTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await frame in stream {
                guard !Task.isCancelled else { return }
                await self.handle(frame)
            }
        }
    }

    private func handle(_ frame: AgentSyncFrame) async {
        let event: GuiEventFrame
        do {
            event = try decoder.decode(GuiEventFrame.self, from: frame.payload)
        } catch {
            await recordMalformedFrame()
            return
        }
        guard event.epoch == directory.epoch else {
            triggerResync()
            return
        }
        switch event.payload {
        case .sessionUpserted(let value):
            directory.apply(.sessionUpserted(value.session), origin: .live)
        case .sessionRemoved(let value):
            directory.apply(.sessionRemoved(id: value.sessionID, version: value.version), origin: .live)
        case .entriesAppended(let value):
            guard let sessionID = sessionID(for: event, topic: frame.topic),
                  let conversation = conversations[sessionID] else { return }
            conversation.apply(.entriesAppended(journalID: value.journalID, entries: value.entries), origin: .live)
            clearStreamingTailIfCommitted(sessionID: sessionID, conversation: conversation)
            scheduleTailPullIfNeeded(for: conversation)
        case .entryReplaced(let value):
            guard let sessionID = sessionID(for: event, topic: frame.topic),
                  let conversation = conversations[sessionID] else { return }
            conversation.apply(.entryReplaced(value.entry), origin: .live)
        case .journalReset(let value):
            guard let conversation = conversations[value.sessionID] else { return }
            conversation.apply(
                .journalReset(sessionID: value.sessionID, newJournal: value.newJournalID, tailSeq: value.tailSeq),
                origin: .live
            )
            streamingTails[value.sessionID] = nil
            scheduleTailPullIfNeeded(for: conversation)
        case .sendState(let value):
            guard let conversation = conversations[value.ticket.sessionID] else { return }
            conversation.apply(.sendTicketChanged(value.ticket), origin: .live)
        case .askState(let value):
            guard let conversation = conversations[value.ask.sessionID] else { return }
            conversation.apply(.askChanged(value.ask), origin: .live)
        case .streamTick(let value):
            guard let sessionID = sessionID(for: event, topic: frame.topic),
                  let conversation = conversations[sessionID],
                  conversation.journalID == value.journalID else { return }
            guard !value.textTail.isEmpty else {
                streamingTails[sessionID] = nil
                return
            }
            guard conversation.tailSeq == value.afterSeq else { return }
            streamingTails[sessionID] = AgentStreamingTail(
                journalID: value.journalID,
                afterSeq: value.afterSeq,
                textTail: value.textTail,
                revision: value.revision
            )
        case .unknown:
            return
        }
    }

    private func recordMalformedFrame() async {
        malformedFrameCount += 1
        let now = await syncClock.nowMilliseconds()
        malformedFrameTimes.append(now)
        malformedFrameTimes = malformedFrameTimes.filter { now - $0 <= 10_000 }
        if malformedFrameTimes.count >= 3 {
            malformedFrameTimes.removeAll()
            triggerResync()
        }
    }

    private func scheduleTailPullIfNeeded(for conversation: ConversationReplica) {
        guard conversation.needsTailPull else { return }
        let sessionID = conversation.sessionID
        tailPullTasks[sessionID]?.cancel()
        tailPullTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncClock.sleep(milliseconds: 250)
            guard !Task.isCancelled else { return }
            do {
                try await self.pullTail(sessionID: sessionID)
            } catch {
                self.scheduleRetry(reason: Self.errorDescription(error))
            }
            self.tailPullTasks[sessionID] = nil
        }
    }

    private func pullTail(sessionID: AgentSessionID) async throws {
        guard let conversation = conversations[sessionID] else {
            throw AgentSyncError.conversationNotOpen
        }
        let result = try await coalescedPage(
            sessionID: sessionID,
            journalID: conversation.journalID,
            anchor: .tail,
            cursor: nil
        )
        merge(result, into: conversation, retaining: .newest)
    }

    private func merge(
        _ result: GuiEntriesResult,
        into conversation: ConversationReplica,
        retaining requestedEdge: ConversationPageRetentionEdge,
        replacingWindow: Bool = false
    ) {
        let edge: ConversationPageRetentionEdge = result.requiresPagingRestart ? .newest : requestedEdge
        conversation.mergePage(
            journal: result.journalID,
            entries: result.entries,
            windowStart: result.windowStart,
            windowEnd: result.windowEnd,
            tailSeq: result.tailSeq,
            hasMoreBefore: result.hasMoreBefore,
            hasMoreAfter: result.hasMoreAfter,
            startCursor: result.startCursor,
            endCursor: result.endCursor,
            tailCursor: result.tailCursor,
            requiresPagingRestart: result.requiresPagingRestart,
            replacingWindow: replacingWindow || result.requiresPagingRestart,
            retaining: edge
        )
        hasMoreBeforeBySession[conversation.sessionID] = result.hasMoreBefore
        hasMoreAfterBySession[conversation.sessionID] = result.hasMoreAfter
        clearStreamingTailIfCommitted(sessionID: conversation.sessionID, conversation: conversation)
        scheduleTailPullIfNeeded(for: conversation)
    }

    private func clearStreamingTailIfCommitted(sessionID: AgentSessionID, conversation: ConversationReplica) {
        guard let tail = streamingTails[sessionID],
              conversation.journalID == tail.journalID,
              conversation.tailSeq.rawValue > tail.afterSeq.rawValue else { return }
        streamingTails[sessionID] = nil
    }

    private func ensureConnected() throws {
        guard connectivity.phase == .connected else {
            throw AgentSyncError.offline
        }
    }

}
