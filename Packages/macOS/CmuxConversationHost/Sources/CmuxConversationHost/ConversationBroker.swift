public import Foundation
public import CmuxConversation
import CryptoKit

/// Durable, provider-neutral broker for managed Codex, Claude Code, and OpenCode conversations.
public actor ConversationBroker: ConversationClient {
    private struct SessionRecord: Codable, Sendable {
        var session: ConversationSession
        var target: ConversationLaunchTarget
        var commandFingerprints: [String: String]

        init(session: ConversationSession, target: ConversationLaunchTarget, commandFingerprints: [String: String] = [:]) {
            self.session = session
            self.target = target
            self.commandFingerprints = commandFingerprints
        }

        private enum CodingKeys: String, CodingKey { case session, target, commandFingerprints }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            session = try container.decode(ConversationSession.self, forKey: .session)
            target = try container.decode(ConversationLaunchTarget.self, forKey: .target)
            commandFingerprints = try container.decodeIfPresent([String: String].self, forKey: .commandFingerprints) ?? [:]
        }
    }

    private struct SessionState: Sendable {
        var session: ConversationSession
        let target: ConversationLaunchTarget
        let journal: ConversationJournal
        var capabilities: ConversationCapabilities
        var items: [ConversationItem]
        var pendingRequests: [ConversationRequest]
        var queued: [ConversationQueueItem]
        var receipts: [ConversationReceipt]
        var cursor: ConversationCursor
        var currentTurnID: ConversationTurnID?
        var dispatchingTurn: Bool
        var connection: (any ConversationProviderConnection)?
        var eventTask: Task<Void, Never>?
        var connectionToken: UUID?
        var appendTail: Task<Void, any Error>?
        var appendRevision: UInt64
        var appendFailure: String?
        var publishedCursor: ConversationCursor
        var pendingPublications: [ConversationCursor: ConversationEvent]
        var commandFingerprints: [ConversationCommandID: String]
        var inFlightCommands: [ConversationCommandID: Task<ConversationReceipt, Never>]
    }

    private struct CreationReservation: Codable, Hashable, Sendable {
        let sessionID: ConversationID
        let fingerprint: String
    }

    /// Only stable client semantics participate in create idempotency. Launch targets and resolved
    /// directories are host derived and may legitimately differ when a retry is routed through a new
    /// workspace context; the first reservation still pins the actual target/session.
    private struct CreateFingerprint: Codable, Hashable, Sendable {
        let provider: ConversationProvider
        let workspaceID: String
        let title: String?
    }

    private struct Subscriber {
        let after: ConversationCursor
        let continuation: AsyncThrowingStream<ConversationEvent, any Error>.Continuation
    }

    private let directory: URL
    private let snapshotInterval: Int
    private let onChange: (@Sendable (ConversationID, ConversationCursor) -> Void)?
    private let adapters: [ConversationProvider: any ConversationProviderAdapter]
    private var sessions: [ConversationID: SessionState] = [:]
    private var creationReservations: [ConversationCommandID: CreationReservation] = [:]
    private var subscribers: [ConversationID: [UUID: Subscriber]] = [:]
    private let encoder = JSONEncoder()
    private var isShutdown = false
    private var attachmentTasks: [ConversationID: Task<Void, any Error>] = [:]

    /// Creates an account-scoped broker.
    /// - Parameters:
    ///   - directory: Private durable storage root for this account and app bundle.
    ///   - adapters: Provider adapters. When omitted, native Codex, Claude, and OpenCode adapters are created.
    ///   - onChange: Optional revision notification callback; the callback receives only session and cursor.
    ///   - snapshotInterval: Number of events between crash-safe snapshots.
    public init(directory: URL, adapters: [any ConversationProviderAdapter]? = nil, onChange: (@Sendable (ConversationID, ConversationCursor) -> Void)? = nil, snapshotInterval: Int = 32) throws {
        self.directory = directory
        self.snapshotInterval = max(1, snapshotInterval)
        self.onChange = onChange
        let selected = adapters ?? ConversationBroker.defaultAdapters()
        self.adapters = Dictionary(uniqueKeysWithValues: selected.map { ($0.provider, $0) })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(0o700)])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o700)], ofItemAtPath: directory.path)
        let adapterMap = self.adapters
        self.creationReservations = try Self.readCreationReservations(directory: directory)
        self.sessions = try Self.readPersistedSessions(directory: directory, adapters: adapterMap)
    }

    /// Builds native process adapters without global state.
    public static func defaultAdapters() -> [any ConversationProviderAdapter] {
        let factory = ProcessConversationTransportFactory()
        return [CodexConversationAdapter(factory: factory), ClaudeCodeConversationAdapter(factory: factory), OpenCodeConversationAdapter(factory: OpenCodeHTTPTransportFactory())]
    }

    /// Reopens persisted sessions whose native providers support resume.
    public func restore() async {
        guard !isShutdown else { return }
        for id in sessions.keys {
            guard let state = sessions[id], state.connection == nil, state.session.providerSessionID != nil, let adapter = adapters[state.session.provider] else { continue }
            do { try await attach(id: id, adapter: adapter) }
            catch {
                sessions[id]?.session.state = .stopped
                sessions[id]?.session.updatedAt = Date()
                if let state = sessions[id] { try? persist(state) }
            }
        }
    }

    /// Lists sessions in stable updated-time order.
    public func listSessions() async throws -> [ConversationSession] { sessions.values.map(\.session).sorted { $0.updatedAt > $1.updatedAt } }

    /// Creates and starts a provider session, idempotently when `requestID` repeats.
    public func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession {
        guard !isShutdown else { throw ConversationBrokerError.brokerShutDown }
        let requestFingerprint = try Self.fingerprint(CreateFingerprint(provider: request.provider, workspaceID: request.workspaceID, title: request.title))
        if let requestID = request.requestID, let reservation = creationReservations[requestID] {
            guard let existing = sessions[reservation.sessionID] else {
                throw ConversationBrokerError.creationUncertain(requestID)
            }
            let legacyMatches = reservation.fingerprint.hasPrefix("legacy:") && existing.session.provider == request.provider && existing.session.workspaceID == request.workspaceID && (request.title ?? request.provider.rawValue.capitalized) == existing.session.title
            guard reservation.fingerprint == requestFingerprint || legacyMatches else {
                throw ConversationBrokerError.idempotencyConflict("create request ID was reused with a different payload")
            }
            return existing.session
        }
        guard let adapter = adapters[request.provider] else { throw ConversationProviderError.unsupported("No adapter for \(request.provider.rawValue)") }
        let id = ConversationID(rawValue: UUID().uuidString)
        if let requestID = request.requestID {
            creationReservations[requestID] = CreationReservation(sessionID: id, fingerprint: requestFingerprint)
            try persistCreationReservations()
        }
        let title = request.title?.isEmpty == false ? request.title! : request.provider.rawValue.capitalized
        var session = ConversationSession(id: id, provider: request.provider, title: title, workspaceID: request.workspaceID, directory: request.directory)
        let journal = try ConversationJournal(directory: directory.appendingPathComponent(id.rawValue, isDirectory: true))
        var capabilities = adapter.capabilities
        capabilities.features.insert("queue")
        let state = SessionState(session: session, target: request.launchTarget, journal: journal, capabilities: capabilities, items: [], pendingRequests: [], queued: [], receipts: [], cursor: 0, currentTurnID: nil, dispatchingTurn: false, connection: nil, eventTask: nil, connectionToken: nil, appendTail: nil, appendRevision: 0, appendFailure: nil, publishedCursor: 0, pendingPublications: [:], commandFingerprints: [:], inFlightCommands: [:])
        sessions[id] = state
        try persist(state)
        do {
            try await attach(id: id, adapter: adapter)
            session = sessions[id]!.session
            if let requestID = request.requestID { let receipt = ConversationReceipt(id: requestID, sessionID: id, state: .applied, reason: nil, eventSequence: sessions[id]!.cursor, generation: session.generation); try await recordReceipt(receipt, id: id) }
            return session
        } catch {
            sessions[id]!.session.state = .failed
            try? persist(sessions[id]!)
            throw error
        }
    }

    /// Reads the complete in-memory projection at its current cursor.
    public func snapshot(sessionID: ConversationID) async throws -> ConversationSnapshot {
        guard sessions[sessionID] != nil else { throw ConversationBrokerError.sessionNotFound(sessionID) }
        try await awaitDurable(sessionID: sessionID)
        guard let state = sessions[sessionID] else { throw ConversationBrokerError.sessionNotFound(sessionID) }
        return ConversationSnapshot(session: state.session, cursor: state.cursor, generation: state.session.generation, items: state.items, pendingRequests: state.pendingRequests, queued: state.queued, receipts: Array(state.receipts.suffix(64)), activeTurnID: state.currentTurnID, isTurnRunning: state.currentTurnID != nil || state.dispatchingTurn, capabilities: state.capabilities)
    }

    /// Replays at most 256 events and approximately 1 MiB after a cursor.
    public func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent] {
        guard sessions[sessionID] != nil else { throw ConversationBrokerError.sessionNotFound(sessionID) }
        try await awaitDurable(sessionID: sessionID)
        guard let state = sessions[sessionID] else { throw ConversationBrokerError.sessionNotFound(sessionID) }
        let events = try await state.journal.events(after: after, limit: 256)
        var result: [ConversationEvent] = []
        var bytes = 0
        for event in events {
            let size = try encoder.encode(event).count
            if !result.isEmpty && bytes + size > 1_048_576 { break }
            guard size <= 1_048_576 else { throw ConversationBrokerError.eventTooLarge(event.sequence) }
            result.append(event); bytes += size
        }
        return result
    }

    /// Registers a live stream before callers perform snapshot and replay.
    public func events(sessionID: ConversationID, after: ConversationCursor = 0) async -> AsyncThrowingStream<ConversationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ConversationEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        guard sessions[sessionID] != nil else { continuation.finish(throwing: ConversationBrokerError.sessionNotFound(sessionID)); return stream }
        let id = UUID()
        subscribers[sessionID, default: [:]][id] = Subscriber(after: after, continuation: continuation)
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeSubscriber(sessionID: sessionID, id: id) } }
        return stream
    }

    /// Executes one command with generation and turn preconditions.
    public func execute(_ envelope: ConversationCommandEnvelope) async throws -> ConversationReceipt {
        guard !isShutdown else { throw ConversationBrokerError.brokerShutDown }
        guard sessions[envelope.sessionID] != nil else { throw ConversationBrokerError.sessionNotFound(envelope.sessionID) }
        let id = envelope.sessionID
        let fingerprint = try Self.fingerprint(envelope.command)
        if let known = sessions[id]!.commandFingerprints[envelope.commandID] {
            guard known == fingerprint else {
                return ConversationReceipt(id: envelope.commandID, sessionID: id, state: .rejected, reason: "command ID was reused with a different payload", generation: sessions[id]!.session.generation)
            }
            if let existing = sessions[id]!.receipts.first(where: { $0.id == envelope.commandID }) { return existing }
            if let inFlight = sessions[id]!.inFlightCommands[envelope.commandID] { return await inFlight.value }
            // A reservation with no receipt survived a process crash. It is unsafe to retry because the
            // provider may have accepted the command before the host stopped.
            let uncertain = ConversationReceipt(id: envelope.commandID, sessionID: id, state: .uncertain, reason: "previous command attempt has no durable outcome", generation: sessions[id]!.session.generation)
            try? await recordReceipt(uncertain, id: id)
            return uncertain
        }

        // Reserve the command and persist its fingerprint before the first await. Retries can therefore
        // distinguish an identical in-flight command from a payload conflict or a crash-uncertain retry.
        sessions[id]!.commandFingerprints[envelope.commandID] = fingerprint
        do { try persist(sessions[id]!) }
        catch {
            sessions[id]!.commandFingerprints.removeValue(forKey: envelope.commandID)
            throw error
        }
        let task = Task { [weak self] in
            guard let self else {
                return ConversationReceipt(id: envelope.commandID, sessionID: id, state: .uncertain, reason: "conversation broker deallocated", generation: "unknown")
            }
            return await self.runReserved(envelope)
        }
        sessions[id]!.inFlightCommands[envelope.commandID] = task
        return await task.value
    }

    private func runReserved(_ envelope: ConversationCommandEnvelope) async -> ConversationReceipt {
        let id = envelope.sessionID
        defer { sessions[id]?.inFlightCommands.removeValue(forKey: envelope.commandID) }
        guard let state = sessions[id] else {
            return ConversationReceipt(id: envelope.commandID, sessionID: id, state: .uncertain, reason: "conversation session disappeared", generation: "unknown")
        }
        do {
            if let expected = envelope.expectedGeneration, expected != state.session.generation {
                return try await reject(envelope, reason: "stale provider generation")
            }
            if let expectedTurn = envelope.expectedTurnID, expectedTurn != state.currentTurnID {
                return try await reject(envelope, reason: "stale active turn")
            }
            let accepted = ConversationReceipt(id: envelope.commandID, sessionID: id, state: .accepted, generation: state.session.generation)
            try await recordReceipt(accepted, id: id)
            return try await apply(envelope.command, commandID: envelope.commandID, id: id, expectedGeneration: envelope.expectedGeneration, expectedTurnID: envelope.expectedTurnID)
        } catch let error as ConversationProviderError {
            return await finishFailedCommand(envelope, error: error, state: Self.receiptState(for: error))
        } catch {
            return await finishFailedCommand(envelope, errorDescription: error.localizedDescription, state: .uncertain)
        }
    }

    private static func receiptState(for error: ConversationProviderError) -> ConversationReceiptState {
        switch error {
        case .unsupported, .rejected, .staleGeneration: .rejected
        case .unavailable, .malformed: .uncertain
        }
    }

    private func finishFailedCommand(_ envelope: ConversationCommandEnvelope, error: ConversationProviderError? = nil, errorDescription: String? = nil, state: ConversationReceiptState) async -> ConversationReceipt {
        let description = error?.description ?? errorDescription ?? "command failed"
        let receipt = ConversationReceipt(id: envelope.commandID, sessionID: envelope.sessionID, state: state, reason: description, generation: sessions[envelope.sessionID]?.session.generation ?? "unknown")
        do { try await recordReceipt(receipt, id: envelope.sessionID) } catch { return receipt }
        return receipt
    }

    /// Reads a durable command receipt without dispatching it.
    public func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt? { try await receipt(sessionID: query.sessionID, commandID: query.commandID) }

    /// Reads a durable command receipt without dispatching it.
    public func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt? { guard let state = sessions[sessionID] else { throw ConversationBrokerError.sessionNotFound(sessionID) }; return state.receipts.first(where: { $0.id == commandID }) }

    /// Closes all provider connections and event streams.
    public func shutdown() async {
        isShutdown = true
        for task in attachmentTasks.values { task.cancel() }
        attachmentTasks.removeAll()
        for id in sessions.keys { await close(id: id) }
        for values in subscribers.values { for subscriber in values.values { subscriber.continuation.finish() } }
        subscribers.removeAll()
    }

    private func apply(_ command: ConversationCommand, commandID: ConversationCommandID, id: ConversationID, expectedGeneration: ConversationGeneration? = nil, expectedTurnID: ConversationTurnID? = nil) async throws -> ConversationReceipt {
        switch command {
        case .rename(let title): sessions[id]!.session.title = title; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .setPinned(let value): sessions[id]!.session.isPinned = value; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .setArchived(let value): sessions[id]!.session.isArchived = value; sessions[id]!.session.state = value ? .archived : .ready; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .configure(let model, let effort, let speed):
            let capabilities = sessions[id]!.capabilities
            if let model, !capabilities.models.isEmpty, !capabilities.models.contains(model) { throw ConversationProviderError.rejected("model is not supported by provider") }
            if let effort, !capabilities.efforts.isEmpty, !capabilities.efforts.contains(effort) { throw ConversationProviderError.rejected("effort is not supported by provider") }
            if let speed, !capabilities.speeds.isEmpty, !capabilities.speeds.contains(speed) { throw ConversationProviderError.rejected("speed is not supported by provider") }
            guard let connection = sessions[id]!.connection else { throw ConversationProviderError.unavailable("provider connection is not ready") }
            try await connection.send(.configure(model: model, effort: effort, speed: speed))
            sessions[id]!.session.model = model; sessions[id]!.session.effort = effort; sessions[id]!.session.speed = speed; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .queue(let text):
            if sessions[id]!.currentTurnID == nil && !sessions[id]!.dispatchingTurn {
                if sessions[id]!.connection == nil {
                    guard sessions[id]!.session.providerSessionID != nil else { throw ConversationProviderError.unavailable("Provider session cannot be resumed safely") }
                    guard let adapter = adapters[sessions[id]!.session.provider] else { throw ConversationProviderError.unsupported("No adapter for provider") }
                    try await ensureAttached(id: id, adapter: adapter)
                }
                let item = ConversationQueueItem(id: ConversationItemID(rawValue: UUID().uuidString), commandID: commandID, text: text, position: sessions[id]!.queued.count)
                sessions[id]!.queued.append(item)
                return try await drainQueue(id: id, commandID: commandID)
            }
            let item = ConversationQueueItem(id: ConversationItemID(rawValue: UUID().uuidString), commandID: commandID, text: text, position: sessions[id]!.queued.count)
            sessions[id]!.queued.append(item)
            try await emitQueue(id: id); return try await applied(commandID, id: id)
        case .editQueued(let itemID, let text):
            guard let index = sessions[id]!.queued.firstIndex(where: { $0.id == itemID }) else { throw ConversationProviderError.rejected("queued item not found") }
            guard !sessions[id]!.queued[index].isDelivering else { throw ConversationProviderError.rejected("queued item is already being delivered") }
            sessions[id]!.queued[index].text = text; try await emitQueue(id: id); return try await applied(commandID, id: id)
        case .cancelQueued(let itemID):
            guard let index = sessions[id]!.queued.firstIndex(where: { $0.id == itemID }) else { throw ConversationProviderError.rejected("queued item not found") }
            guard !sessions[id]!.queued[index].isDelivering else { throw ConversationProviderError.rejected("queued item is already being delivered") }
            let draftText = sessions[id]!.queued[index].text
            sessions[id]!.queued.remove(at: index); reindexQueue(id: id); try await emitQueue(id: id); return try await applied(commandID, id: id, draftText: draftText)
        case .startTurn(let text, let model, let effort):
            guard sessions[id]!.currentTurnID == nil && !sessions[id]!.dispatchingTurn else { throw ConversationProviderError.rejected("a turn is already active or being dispatched") }
            if sessions[id]!.connection == nil {
                guard sessions[id]!.session.providerSessionID != nil else { throw ConversationProviderError.unavailable("Provider session cannot be resumed safely") }
                guard let adapter = adapters[sessions[id]!.session.provider] else { throw ConversationProviderError.unsupported("No adapter for provider") }
                try await ensureAttached(id: id, adapter: adapter)
            }
            return try await sendProvider(.startTurn(text: text, model: model ?? sessions[id]!.session.model, effort: effort ?? sessions[id]!.session.effort), commandID: commandID, id: id, expectedGeneration: expectedGeneration, expectedTurnID: expectedTurnID)
        case .steer(let text): return try await sendProvider(.steer(text: text), commandID: commandID, id: id, expectedGeneration: expectedGeneration, expectedTurnID: expectedTurnID)
        case .interrupt: return try await sendProvider(.interrupt, commandID: commandID, id: id, expectedGeneration: expectedGeneration, expectedTurnID: expectedTurnID)
        case .answerQuestion, .resolveApproval: return try await sendProvider(command, commandID: commandID, id: id, expectedGeneration: expectedGeneration, expectedTurnID: expectedTurnID)
        }
    }

    private func sendProvider(_ command: ConversationCommand, commandID: ConversationCommandID, id: ConversationID, expectedGeneration: ConversationGeneration? = nil, expectedTurnID: ConversationTurnID? = nil) async throws -> ConversationReceipt {
        guard !isShutdown else { throw ConversationProviderError.unavailable("conversation broker is shut down") }
        if let expectedGeneration, expectedGeneration != sessions[id]?.session.generation { throw ConversationProviderError.staleGeneration }
        if let expectedTurnID, expectedTurnID != sessions[id]?.currentTurnID { throw ConversationProviderError.rejected("stale active turn") }
        if case .startTurn = command, sessions[id]!.currentTurnID != nil || sessions[id]!.dispatchingTurn { throw ConversationProviderError.rejected("a turn is already active or being dispatched") }
        guard let connection = sessions[id]?.connection else { throw ConversationProviderError.unavailable("provider connection is not ready") }
        let isStart = if case .startTurn = command { true } else { false }
        if isStart { sessions[id]!.dispatchingTurn = true; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!) }
        do { try await connection.send(command) }
        catch let error as ConversationProviderError {
            if isStart {
                switch error {
                case .unsupported, .rejected, .staleGeneration:
                    sessions[id]!.dispatchingTurn = false
                    try? persist(sessions[id]!)
                case .unavailable, .malformed: break
                }
            }
            throw error
        }
        return try await applied(commandID, id: id)
    }

    private func drainQueue(id: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt {
        guard sessions[id]!.currentTurnID == nil && !sessions[id]!.dispatchingTurn else {
            return try await applied(commandID, id: id)
        }
        guard !sessions[id]!.queued.isEmpty else { return try await applied(commandID, id: id) }
        var item = sessions[id]!.queued[0]; item.isDelivering = true; sessions[id]!.queued[0] = item
        sessions[id]!.dispatchingTurn = true
        try persist(sessions[id]!)
        try await emitQueue(id: id)
        guard let connection = sessions[id]!.connection else { throw ConversationProviderError.unavailable("provider connection is not ready") }
        do { try await connection.send(.startTurn(text: item.text, model: sessions[id]!.session.model, effort: sessions[id]!.session.effort)) }
        catch let error as ConversationProviderError {
            switch error {
            case .unsupported, .rejected, .staleGeneration:
                sessions[id]!.queued[0].isDelivering = false
                sessions[id]!.dispatchingTurn = false
                try? persist(sessions[id]!)
                try? await emitQueue(id: id)
            case .unavailable, .malformed: break
            }
            throw error
        }
        sessions[id]!.queued.removeFirst()
        reindexQueue(id: id)
        try persist(sessions[id]!)
        try await emitQueue(id: id)
        return try await applied(commandID, id: id)
    }

    private func reindexQueue(id: ConversationID) {
        guard var queue = sessions[id]?.queued else { return }
        for index in queue.indices { queue[index].position = index }
        sessions[id]!.queued = queue
    }

    private func applied(_ commandID: ConversationCommandID, id: ConversationID, draftText: String? = nil) async throws -> ConversationReceipt {
        let state = sessions[id]!.session
        let receipt = ConversationReceipt(id: commandID, sessionID: id, state: .applied, eventSequence: sessions[id]!.cursor, generation: state.generation, draftText: draftText)
        try await recordReceipt(receipt, id: id)
        return receipt
    }

    private func reject(_ envelope: ConversationCommandEnvelope, reason: String) async throws -> ConversationReceipt {
        let receipt = ConversationReceipt(id: envelope.commandID, sessionID: envelope.sessionID, state: .rejected, reason: reason, generation: sessions[envelope.sessionID]!.session.generation)
        try await recordReceipt(receipt, id: envelope.sessionID)
        return receipt
    }

    private func recordReceipt(_ receipt: ConversationReceipt, id: ConversationID) async throws {
        guard sessions[id] != nil else { return }
        if let index = sessions[id]!.receipts.firstIndex(where: { $0.id == receipt.id }) { sessions[id]!.receipts[index] = receipt } else { sessions[id]!.receipts.append(receipt) }
        let event = try await appendEvent(id: id, kind: .receipt, receipt: receipt)
        _ = event
        try persist(sessions[id]!)
    }

    private func emitQueue(id: ConversationID) async throws {
        reindexQueue(id: id)
        _ = try await appendEvent(id: id, kind: .queue, queue: sessions[id]!.queued)
    }

    /// Waits until the append chain observed at entry has completed. A revision check handles
    /// actor reentrancy when a second event is reserved while the first write is awaiting I/O.
    private func awaitDurable(sessionID: ConversationID) async throws {
        while true {
            guard let state = sessions[sessionID] else { throw ConversationBrokerError.sessionNotFound(sessionID) }
            if let failure = state.appendFailure { throw ConversationBrokerError.durabilityFailed(failure) }
            let revision = state.appendRevision
            guard let tail = state.appendTail else { return }
            do { try await tail.value }
            catch {
                sessions[sessionID]?.appendFailure = error.localizedDescription
                throw ConversationBrokerError.durabilityFailed(error.localizedDescription)
            }
            guard sessions[sessionID]?.appendRevision == revision else { continue }
            return
        }
    }

    private func appendEvent(id: ConversationID, kind: ConversationEventKind, turnID: ConversationTurnID? = nil, item: ConversationItem? = nil, itemUpdate: ConversationItemUpdateMode? = nil, request: ConversationRequest? = nil, queue: [ConversationQueueItem]? = nil, receipt: ConversationReceipt? = nil, state: String? = nil, rawPayload: ConversationJSONValue? = nil) async throws -> ConversationEvent {
        guard sessions[id] != nil else { throw ConversationBrokerError.sessionNotFound(id) }
        if let failure = sessions[id]!.appendFailure { throw ConversationBrokerError.durabilityFailed(failure) }
        // Reserve the cursor and chain the write synchronously. Every subsequent task awaits its
        // predecessor inside the task, so concurrent actor callers cannot reorder journal records.
        let sequence = sessions[id]!.cursor + 1
        sessions[id]!.cursor = sequence
        let journal = sessions[id]!.journal
        let prior = sessions[id]!.appendTail
        let eventItem = item.map { ConversationItem(id: $0.id, sequence: sequence, turnID: $0.turnID, kind: $0.kind, role: $0.role, text: $0.text, tool: $0.tool, plan: $0.plan, diff: $0.diff, artifact: $0.artifact, usage: $0.usage, rawPayload: $0.rawPayload) }
        if let item, let index = sessions[id]!.items.firstIndex(where: { $0.id == item.id }) {
            let projected = sessions[id]!.items[index]
            sessions[id]!.items[index] = ConversationItem(id: projected.id, sequence: sequence, turnID: projected.turnID, kind: projected.kind, role: projected.role, text: projected.text, tool: projected.tool, plan: projected.plan, diff: projected.diff, artifact: projected.artifact, usage: projected.usage, rawPayload: projected.rawPayload)
        }
        let event = ConversationEvent(sessionID: id, sequence: sequence, generation: sessions[id]!.session.generation, kind: kind, turnID: turnID, item: eventItem, itemUpdate: itemUpdate, request: request, queue: queue, receipt: receipt, state: state, rawPayload: rawPayload)
        let appendTask = Task {
            if let prior { try await prior.value }
            try await journal.append(event)
        }
        sessions[id]!.appendTail = appendTask
        sessions[id]!.appendRevision &+= 1
        do { try await appendTask.value }
        catch {
            sessions[id]!.appendFailure = error.localizedDescription
            throw ConversationBrokerError.durabilityFailed(error.localizedDescription)
        }
        sessions[id]!.pendingPublications[sequence] = event
        while let next = sessions[id]!.pendingPublications[sessions[id]!.publishedCursor + 1] {
            sessions[id]!.pendingPublications.removeValue(forKey: next.sequence)
            sessions[id]!.publishedCursor = next.sequence
            broadcast(next)
            onChange?(id, next.sequence)
        }
        if sequence % ConversationCursor(snapshotInterval) == 0 { try await writeSnapshot(id: id) }
        return event
    }

    private func writeSnapshot(id: ConversationID) async throws {
        try await awaitDurable(sessionID: id)
        guard let state = sessions[id] else { return }
        let snapshot = ConversationSnapshot(session: state.session, cursor: state.cursor, generation: state.session.generation, items: state.items, pendingRequests: state.pendingRequests, queued: state.queued, receipts: Array(state.receipts.suffix(64)), activeTurnID: state.currentTurnID, isTurnRunning: state.currentTurnID != nil || state.dispatchingTurn, capabilities: state.capabilities)
        try await state.journal.write(snapshot: snapshot)
    }

    private func attach(id: ConversationID, adapter: any ConversationProviderAdapter) async throws {
        guard let state = sessions[id] else { throw ConversationBrokerError.sessionNotFound(id) }
        guard sessions[id]?.connection == nil else { return }
        guard !isShutdown else { throw ConversationBrokerError.brokerShutDown }
        let token = UUID()
        sessions[id]!.connectionToken = token
        let connection = try await adapter.open(session: state.session, target: state.target)
        guard !isShutdown, sessions[id]?.connectionToken == token else {
            await connection.close()
            throw ConversationBrokerError.brokerShutDown
        }
        sessions[id]!.connection = connection
        if let nativeID = await connection.providerSessionID() {
            guard !isShutdown, sessions[id]?.connectionToken == token else { await connection.close(); sessions[id]?.connection = nil; throw ConversationBrokerError.brokerShutDown }
            sessions[id]!.session.providerSessionID = nativeID
        }
        if var capabilities = await connection.capabilities() {
            guard !isShutdown, sessions[id]?.connectionToken == token else { await connection.close(); sessions[id]?.connection = nil; throw ConversationBrokerError.brokerShutDown }
            capabilities.features.insert("queue"); sessions[id]!.capabilities = capabilities
        }
        guard !isShutdown, sessions[id]?.connectionToken == token else { await connection.close(); sessions[id]?.connection = nil; throw ConversationBrokerError.brokerShutDown }
        sessions[id]!.session.state = .ready
        try persist(sessions[id]!)
        let task = Task { [weak self] in
            do {
                for try await event in connection.events { await self?.ingest(event, id: id, token: token) }
                await self?.markProviderRestarted(id: id, token: token, reason: "provider stream ended")
            } catch { await self?.markProviderRestarted(id: id, token: token, reason: error.localizedDescription) }
        }
        sessions[id]!.eventTask = task
    }

    private func ensureAttached(id: ConversationID, adapter: any ConversationProviderAdapter) async throws {
        guard sessions[id]?.connection == nil else { return }
        if let task = attachmentTasks[id] {
            try await task.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { throw ConversationBrokerError.brokerShutDown }
            try await self.attach(id: id, adapter: adapter)
        }
        attachmentTasks[id] = task
        defer { attachmentTasks.removeValue(forKey: id) }
        try await task.value
    }

    private func ingest(_ providerEvent: ConversationProviderEvent, id: ConversationID, token: UUID) async {
        guard sessions[id]?.connectionToken == token else { return }
        guard var state = sessions[id] else { return }
        var item: ConversationItem?
        var compactItem: ConversationItem?
        var normalizedRequest: ConversationRequest?
        var didFinishTurn = false
        if providerEvent.kind == .item {
            let itemID = providerEvent.itemID ?? ConversationItemID(rawValue: UUID().uuidString)
            let incoming = ConversationItem(id: itemID, sequence: state.cursor + 1, turnID: providerEvent.turnID, kind: providerEvent.itemKind ?? .unknown("provider"), role: providerEvent.role, text: providerEvent.text, tool: providerEvent.tool, plan: providerEvent.plan, diff: providerEvent.diff, artifact: providerEvent.artifact, usage: providerEvent.usage, rawPayload: providerEvent.rawPayload)
            compactItem = incoming
            item = incoming.applying(to: state.items.first(where: { $0.id == itemID }), mode: providerEvent.itemUpdate)
            if let index = state.items.firstIndex(where: { $0.id == itemID }) { state.items[index] = item! } else { state.items.append(item!) }
        } else if case .unknown(let unknownKind) = providerEvent.kind, providerEvent.rawPayload != nil {
            let itemID = providerEvent.itemID ?? ConversationItemID(rawValue: "unknown:\(state.cursor + 1)")
            let incoming = ConversationItem(id: itemID, sequence: state.cursor + 1, turnID: providerEvent.turnID, kind: .unknown(unknownKind), role: providerEvent.role, text: providerEvent.text, rawPayload: providerEvent.rawPayload)
            compactItem = incoming
            item = incoming.applying(to: state.items.first(where: { $0.id == itemID }), mode: providerEvent.itemUpdate)
            if let index = state.items.firstIndex(where: { $0.id == itemID }) { state.items[index] = item! } else { state.items.append(item!) }
        }
        if let request = providerEvent.request {
            normalizedRequest = ConversationRequest(id: request.id, turnID: request.turnID, generation: state.session.generation, kind: request.kind, state: request.state, approval: request.approval, question: request.question, rawPayload: request.rawPayload)
            if let index = state.pendingRequests.firstIndex(where: { $0.id == request.id }) { state.pendingRequests[index] = normalizedRequest! } else if normalizedRequest!.state == .pending { state.pendingRequests.append(normalizedRequest!) }
        }
        if providerEvent.kind == .turn || providerEvent.kind == .run {
            if let stateLabel = providerEvent.state, ["completed", "succeeded", "failed", "stopped", "cancelled", "idle"].contains(stateLabel) {
                let matchesActiveTurn: Bool
                if let activeTurn = state.currentTurnID {
                    matchesActiveTurn = providerEvent.turnID == activeTurn
                } else {
                    matchesActiveTurn = state.dispatchingTurn && providerEvent.turnID != nil
                }
                if matchesActiveTurn { state.currentTurnID = nil; state.dispatchingTurn = false; didFinishTurn = true }
            }
            else if providerEvent.turnID != nil { state.currentTurnID = providerEvent.turnID; state.dispatchingTurn = false }
        }
        state.session.updatedAt = Date()
        sessions[id] = state
        do { _ = try await appendEvent(id: id, kind: providerEvent.kind, turnID: providerEvent.turnID, item: compactItem, itemUpdate: providerEvent.itemUpdate, request: normalizedRequest, state: providerEvent.state, rawPayload: providerEvent.rawPayload) }
        catch { await markProviderRestarted(id: id, token: token, reason: error.localizedDescription); return }
        if didFinishTurn, sessions[id]!.currentTurnID == nil, !sessions[id]!.dispatchingTurn, !sessions[id]!.queued.isEmpty, !sessions[id]!.queued[0].isDelivering { let command = sessions[id]!.queued[0].commandID; _ = try? await drainQueue(id: id, commandID: command) }
    }

    private func markProviderRestarted(id: ConversationID, token: UUID, reason: String) async {
        guard sessions[id]?.connectionToken == token else { return }
        sessions[id]!.connection = nil
        sessions[id]!.connectionToken = nil
        sessions[id]!.eventTask = nil
        sessions[id]!.session.generation = UUID().uuidString
        sessions[id]!.session.state = .stopped
        sessions[id]!.session.updatedAt = Date()
        sessions[id]!.currentTurnID = nil
        sessions[id]!.dispatchingTurn = false
        let generation = sessions[id]!.session.generation
        sessions[id]!.pendingRequests = sessions[id]!.pendingRequests.map { ConversationRequest(id: $0.id, turnID: $0.turnID, generation: generation, kind: $0.kind, state: .stale, approval: $0.approval, question: $0.question, rawPayload: $0.rawPayload) }
        try? persist(sessions[id]!)
        _ = try? await appendEvent(id: id, kind: .restarted, state: reason)
    }

    private func close(id: ConversationID) async {
        attachmentTasks[id]?.cancel()
        attachmentTasks.removeValue(forKey: id)
        guard let connection = sessions[id]?.connection else { sessions[id]?.connectionToken = nil; return }
        sessions[id]!.connectionToken = nil
        await connection.close()
        sessions[id]!.connection = nil
        sessions[id]!.eventTask?.cancel()
        sessions[id]!.eventTask = nil
    }

    private func broadcast(_ event: ConversationEvent) {
        guard var values = subscribers[event.sessionID] else { return }
        for (id, subscriber) in values {
            guard event.sequence > subscriber.after else { continue }
            let result = subscriber.continuation.yield(event)
            if case .dropped = result { subscriber.continuation.finish(throwing: ConversationBrokerError.eventStreamOverflow); values.removeValue(forKey: id) }
        }
        subscribers[event.sessionID] = values
    }

    private func removeSubscriber(sessionID: ConversationID, id: UUID) { subscribers[sessionID]?.removeValue(forKey: id) }

    private static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persist(_ state: SessionState) throws {
        let fingerprints = state.commandFingerprints.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }
        let record = SessionRecord(session: state.session, target: state.target, commandFingerprints: fingerprints)
        let data = try encoder.encode(record)
        let url = directory.appendingPathComponent(state.session.id.rawValue, isDirectory: true).appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: Int(0o700)])
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: url.path)
    }

    private func persistCreationReservations() throws {
        let url = directory.appendingPathComponent("creation-reservations.json")
        let raw = creationReservations.reduce(into: [String: CreationReservation]()) { $0[$1.key.rawValue] = $1.value }
        let data = try encoder.encode(raw)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: url.path)
    }

    private static func readCreationReservations(directory: URL) throws -> [ConversationCommandID: CreationReservation] {
        let url = directory.appendingPathComponent("creation-reservations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ConversationJournalError.corruptSession(url.path) }
        guard !data.isEmpty else { throw ConversationJournalError.corruptSession(url.path) }
        let decoder = JSONDecoder()
        if let raw = try? decoder.decode([String: CreationReservation].self, from: data) {
            return raw.reduce(into: [:]) { $0[ConversationCommandID(rawValue: $1.key)] = $1.value }
        }
        // Read the previous command-ID -> session-ID shape only when it is unambiguous. New writes
        // always include the payload fingerprint, so a legacy reservation remains safely bound to its
        // original command but cannot silently accept a different payload.
        if let legacy = try? decoder.decode([String: String].self, from: data) {
            return legacy.reduce(into: [:]) { $0[ConversationCommandID(rawValue: $1.key)] = CreationReservation(sessionID: ConversationID(rawValue: $1.value), fingerprint: "legacy:\($1.value)") }
        }
        throw ConversationJournalError.corruptSession(url.path)
    }

    private static func readPersistedSessions(directory: URL, adapters: [ConversationProvider: any ConversationProviderAdapter]) throws -> [ConversationID: SessionState] {
        let directories: [URL]
        do { directories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) }
        catch { throw ConversationJournalError.corruptSession(directory.path) }
        let decoder = JSONDecoder()
        var loaded: [ConversationID: SessionState] = [:]
        for child in directories {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let url = child.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw ConversationJournalError.corruptSession(url.path) }
            let record: SessionRecord
            do { record = try decoder.decode(SessionRecord.self, from: data) } catch { throw ConversationJournalError.corruptSession(url.path) }
            let journal = try ConversationJournal(directory: child)
            let snapshotURL = child.appendingPathComponent("snapshot.json")
            let snapshot: ConversationSnapshot?
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                do { snapshot = try decoder.decode(ConversationSnapshot.self, from: Data(contentsOf: snapshotURL)) }
                catch { throw ConversationJournalError.corruptSession(snapshotURL.path) }
            } else { snapshot = nil }
            var capabilities = adapters[record.session.provider]?.capabilities ?? ConversationCapabilities(protocolVersion: "unknown", supportsResume: false)
            capabilities.features.insert("queue")
            var fingerprints: [ConversationCommandID: String] = [:]
            for (key, value) in record.commandFingerprints { fingerprints[ConversationCommandID(rawValue: key)] = value }
            var state = SessionState(session: record.session, target: record.target, journal: journal, capabilities: snapshot?.capabilities ?? capabilities, items: snapshot?.items ?? [], pendingRequests: snapshot?.pendingRequests ?? [], queued: snapshot?.queued ?? [], receipts: snapshot?.receipts ?? [], cursor: snapshot?.cursor ?? 0, currentTurnID: snapshot?.activeTurnID, dispatchingTurn: snapshot?.isTurnRunning ?? false, connection: nil, eventTask: nil, connectionToken: nil, appendTail: nil, appendRevision: 0, appendFailure: nil, publishedCursor: snapshot?.cursor ?? 0, pendingPublications: [:], commandFingerprints: fingerprints, inFlightCommands: [:])
            let after = snapshot?.cursor ?? 0
            let events = try Self.decodeDurableEvents(at: child.appendingPathComponent("events.jsonl"))
            if let first = events.first, first.sequence > 1 { throw ConversationJournalError.sequenceMismatch(expected: 1, actual: first.sequence) }
            for event in events where event.sequence > after { Self.apply(event, to: &state) }
            if let last = events.last {
                guard last.sequence >= after else { throw ConversationJournalError.snapshotAhead(after, last.sequence) }
                state.cursor = last.sequence
            } else if after > 0 {
                throw ConversationJournalError.snapshotAhead(after, 0)
            }
            // A process restart invalidates any in-flight native turn/request. Keep queued items
            // marked `isDelivering` so an uncertain provider dispatch is never replayed automatically.
            if record.session.state == .ready || record.session.state == .starting || state.currentTurnID != nil || state.dispatchingTurn {
                state.session.state = state.session.isArchived ? .archived : .stopped
                state.session.generation = UUID().uuidString
                state.currentTurnID = nil
                state.dispatchingTurn = false
                let generation = state.session.generation
                state.pendingRequests = state.pendingRequests.map { request in
                    ConversationRequest(id: request.id, turnID: request.turnID, generation: generation, kind: request.kind, state: .stale, approval: request.approval, question: request.question, rawPayload: request.rawPayload)
                }
                let fingerprints = state.commandFingerprints.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }
                let updatedRecord = SessionRecord(session: state.session, target: state.target, commandFingerprints: fingerprints)
                do {
                    let updatedData = try JSONEncoder().encode(updatedRecord)
                    try updatedData.write(to: url, options: [.atomic])
                    try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: url.path)
                    let restartSnapshot = ConversationSnapshot(session: state.session, cursor: state.cursor, generation: state.session.generation, items: state.items, pendingRequests: state.pendingRequests, queued: state.queued, receipts: Array(state.receipts.suffix(64)), activeTurnID: nil, isTurnRunning: false, capabilities: state.capabilities)
                    let snapshotData = try JSONEncoder().encode(restartSnapshot)
                    let snapshotURL = child.appendingPathComponent("snapshot.json")
                    try snapshotData.write(to: snapshotURL, options: [.atomic])
                    try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: snapshotURL.path)
                } catch {
                    throw ConversationJournalError.corruptSession(url.path)
                }
            }
            loaded[record.session.id] = state
        }
        return loaded
    }

    private static func decodeDurableEvents(at url: URL) throws -> [ConversationEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ConversationJournalError.corruptJournal(url.path) }
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var result: [ConversationEvent] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: true) {
            do { result.append(try decoder.decode(ConversationEvent.self, from: Data(line))) }
            catch { throw ConversationJournalError.corruptJournal(url.path) }
        }
        for (index, event) in result.enumerated() where event.sequence != ConversationCursor(index + 1) {
            throw ConversationJournalError.sequenceMismatch(expected: ConversationCursor(index + 1), actual: event.sequence)
        }
        return result
    }

    private static func apply(_ event: ConversationEvent, to state: inout SessionState) {
        switch event.kind {
        case .item:
            if let item = event.item {
                let projected = item.applying(to: state.items.first(where: { $0.id == item.id }), mode: event.itemUpdate)
                if let index = state.items.firstIndex(where: { $0.id == item.id }) { state.items[index] = projected } else { state.items.append(projected) }
            }
        case .request:
            if let request = event.request { if let index = state.pendingRequests.firstIndex(where: { $0.id == request.id }) { state.pendingRequests[index] = request } else if request.state == .pending { state.pendingRequests.append(request) } }
        case .queue:
            state.queued = event.queue ?? []
            for index in state.queued.indices { state.queued[index].position = index }
        case .receipt:
            if let receipt = event.receipt { if let index = state.receipts.firstIndex(where: { $0.id == receipt.id }) { state.receipts[index] = receipt } else { state.receipts.append(receipt) } }
        case .turn, .run:
            if let turnID = event.turnID, event.state == "running" { state.currentTurnID = turnID; state.dispatchingTurn = false }
            if ["completed", "succeeded", "failed", "stopped", "cancelled", "idle"].contains(event.state ?? "") {
                let matchesActiveTurn: Bool
                if let activeTurn = state.currentTurnID { matchesActiveTurn = event.turnID == activeTurn }
                else { matchesActiveTurn = state.dispatchingTurn && event.turnID != nil }
                if matchesActiveTurn { state.currentTurnID = nil; state.dispatchingTurn = false }
            }
        case .restarted:
            state.session.generation = event.generation; state.session.state = .stopped; state.currentTurnID = nil; state.dispatchingTurn = false
            let generation = state.session.generation
            state.pendingRequests = state.pendingRequests.map { request in ConversationRequest(id: request.id, turnID: request.turnID, generation: generation, kind: request.kind, state: .stale, approval: request.approval, question: request.question, rawPayload: request.rawPayload) }
        case .unknown:
            if let item = event.item {
                let projected = item.applying(to: state.items.first(where: { $0.id == item.id }), mode: event.itemUpdate)
                if let index = state.items.firstIndex(where: { $0.id == item.id }) { state.items[index] = projected } else { state.items.append(projected) }
            }
        }
        state.cursor = max(state.cursor, event.sequence)
    }

}

/// Errors returned by the durable broker.
public enum ConversationBrokerError: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    /// Session does not exist in this account's store.
    case sessionNotFound(ConversationID)
    /// A replay record exceeds the transport envelope.
    case eventTooLarge(ConversationCursor)
    /// A live stream dropped an event and must be rebuilt from a snapshot and replay.
    case eventStreamOverflow
    /// Provider stream ended and pending requests became stale.
    case providerRestarted(String)
    /// A retry reused an idempotency key with a different request body.
    case idempotencyConflict(String)
    /// A create reservation exists but its session record is missing.
    case creationUncertain(ConversationCommandID)
    /// Durable journal writes failed; later events must stop until recovery.
    case durabilityFailed(String)
    /// The broker has been retired during account logout or service replacement.
    case brokerShutDown

    public var description: String {
        switch self {
        case .sessionNotFound(let id): "session not found: \(id.rawValue)"
        case .eventTooLarge(let cursor): "event too large at cursor \(cursor)"
        case .eventStreamOverflow: "event stream overflow; snapshot and replay required"
        case .providerRestarted(let value): "provider restarted: \(value)"
        case .idempotencyConflict(let value): "idempotency conflict: \(value)"
        case .creationUncertain(let id): "creation request has no durable session: \(id.rawValue)"
        case .durabilityFailed(let value): "durability failed: \(value)"
        case .brokerShutDown: "conversation broker is shut down"
        }
    }
}
