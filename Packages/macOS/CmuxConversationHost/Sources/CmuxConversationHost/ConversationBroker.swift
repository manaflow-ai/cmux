public import Foundation
public import CmuxConversation

/// Durable, provider-neutral broker for managed Codex, Claude Code, and OpenCode conversations.
public actor ConversationBroker: ConversationClient {
    private struct SessionRecord: Codable, Sendable {
        var session: ConversationSession
        var target: ConversationLaunchTarget
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
    }

    private let directory: URL
    private let snapshotInterval: Int
    private let onChange: (@Sendable (ConversationID, ConversationCursor) -> Void)?
    private let adapters: [ConversationProvider: any ConversationProviderAdapter]
    private var sessions: [ConversationID: SessionState] = [:]
    private var creationReservations: [ConversationCommandID: ConversationID] = [:]
    private var subscribers: [ConversationID: [UUID: AsyncThrowingStream<ConversationEvent, any Error>.Continuation]] = [:]
    private let encoder = JSONEncoder()

    /// Creates an account-scoped broker.
    /// - Parameters:
    ///   - directory: Private durable storage root for this account and app bundle.
    ///   - adapters: Provider adapters. When omitted, native stdio adapters are created for Codex and Claude; OpenCode requires an HTTP/SSE factory.
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
        try loadCreationReservations()
        try loadPersistedSessions()
    }

    /// Builds native process adapters without global state.
    public static func defaultAdapters() -> [any ConversationProviderAdapter] {
        let factory = ProcessConversationTransportFactory()
        return [CodexConversationAdapter(factory: factory), ClaudeCodeConversationAdapter(factory: factory), OpenCodeConversationAdapter(factory: OpenCodeHTTPTransportFactory())]
    }

    /// Reopens persisted sessions whose native providers support resume.
    public func restore() async {
        for id in sessions.keys {
            guard let state = sessions[id], state.connection == nil, let adapter = adapters[state.session.provider] else { continue }
            do { try await attach(id: id, adapter: adapter) }
            catch { await markProviderRestarted(id: id, reason: error.localizedDescription) }
        }
    }

    /// Lists sessions in stable updated-time order.
    public func listSessions() async throws -> [ConversationSession] { sessions.values.map(\.session).sorted { $0.updatedAt > $1.updatedAt } }

    /// Creates and starts a provider session, idempotently when `requestID` repeats.
    public func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession {
        if let requestID = request.requestID, let reserved = creationReservations[requestID], let existing = sessions[reserved] { return existing.session }
        guard let adapter = adapters[request.provider] else { throw ConversationProviderError.unsupported("No adapter for \(request.provider.rawValue)") }
        let id = ConversationID(rawValue: UUID().uuidString)
        if let requestID = request.requestID { creationReservations[requestID] = id; try persistCreationReservations() }
        let title = request.title?.isEmpty == false ? request.title! : request.provider.rawValue.capitalized
        var session = ConversationSession(id: id, provider: request.provider, title: title, workspaceID: request.workspaceID, directory: request.directory)
        let journal = try ConversationJournal(directory: directory.appendingPathComponent(id.rawValue, isDirectory: true))
        let state = SessionState(session: session, target: request.launchTarget, journal: journal, capabilities: adapter.capabilities, items: [], pendingRequests: [], queued: [], receipts: [], cursor: 0, currentTurnID: nil, dispatchingTurn: false, connection: nil, eventTask: nil)
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
        guard let state = sessions[sessionID] else { throw ConversationBrokerError.sessionNotFound(sessionID) }
        return ConversationSnapshot(session: state.session, cursor: state.cursor, generation: state.session.generation, items: state.items, pendingRequests: state.pendingRequests, queued: state.queued, receipts: Array(state.receipts.suffix(64)), activeTurnID: state.currentTurnID, isTurnRunning: state.currentTurnID != nil || state.dispatchingTurn, capabilities: state.capabilities)
    }

    /// Replays at most 256 events and approximately 1 MiB after a cursor.
    public func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent] {
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
        subscribers[sessionID, default: [:]][id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeSubscriber(sessionID: sessionID, id: id) } }
        _ = after
        return stream
    }

    /// Executes one command with generation and turn preconditions.
    public func execute(_ envelope: ConversationCommandEnvelope) async throws -> ConversationReceipt {
        guard sessions[envelope.sessionID] != nil else { throw ConversationBrokerError.sessionNotFound(envelope.sessionID) }
        if let existing = sessions[envelope.sessionID]!.receipts.first(where: { $0.id == envelope.commandID }) { return existing }
        let id = envelope.sessionID
        guard let state = sessions[id] else { throw ConversationBrokerError.sessionNotFound(id) }
        if let expected = envelope.expectedGeneration, expected != state.session.generation { return try await reject(envelope, reason: "stale provider generation") }
        if let expectedTurn = envelope.expectedTurnID, expectedTurn != state.currentTurnID { return try await reject(envelope, reason: "stale active turn") }
        let accepted = ConversationReceipt(id: envelope.commandID, sessionID: id, state: .accepted, generation: state.session.generation)
        try await recordReceipt(accepted, id: id)
        do {
            let final = try await apply(envelope.command, commandID: envelope.commandID, id: id)
            return final
        } catch let error as ConversationProviderError {
            let state: ConversationReceiptState = if case .rejected = error { .rejected } else { .uncertain }
            let receipt = ConversationReceipt(id: envelope.commandID, sessionID: id, state: state, reason: error.description, generation: sessions[id]!.session.generation)
            try await recordReceipt(receipt, id: id)
            return receipt
        } catch {
            let receipt = ConversationReceipt(id: envelope.commandID, sessionID: id, state: .uncertain, reason: error.localizedDescription, generation: sessions[id]!.session.generation)
            try await recordReceipt(receipt, id: id)
            return receipt
        }
    }

    /// Reads a durable command receipt without dispatching it.
    public func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt? { try await receipt(sessionID: query.sessionID, commandID: query.commandID) }

    /// Reads a durable command receipt without dispatching it.
    public func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt? { guard let state = sessions[sessionID] else { throw ConversationBrokerError.sessionNotFound(sessionID) }; return state.receipts.first(where: { $0.id == commandID }) }

    /// Closes all provider connections and event streams.
    public func shutdown() async {
        for id in sessions.keys { await close(id: id) }
        for values in subscribers.values { for continuation in values.values { continuation.finish() } }
        subscribers.removeAll()
    }

    private func apply(_ command: ConversationCommand, commandID: ConversationCommandID, id: ConversationID) async throws -> ConversationReceipt {
        switch command {
        case .rename(let title): sessions[id]!.session.title = title; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .setPinned(let value): sessions[id]!.session.isPinned = value; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .setArchived(let value): sessions[id]!.session.isArchived = value; sessions[id]!.session.state = value ? .archived : .ready; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .configure(let model, let effort, let speed):
            let capabilities = sessions[id]!.capabilities
            if let model, !capabilities.models.isEmpty, !capabilities.models.contains(model) { throw ConversationProviderError.rejected("model is not supported by provider") }
            if let effort, !capabilities.efforts.isEmpty, !capabilities.efforts.contains(effort) { throw ConversationProviderError.rejected("effort is not supported by provider") }
            if let speed, !capabilities.speeds.isEmpty, !capabilities.speeds.contains(speed) { throw ConversationProviderError.rejected("speed is not supported by provider") }
            sessions[id]!.session.model = model; sessions[id]!.session.effort = effort; sessions[id]!.session.speed = speed; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!); return try await applied(commandID, id: id)
        case .queue(let text):
            let item = ConversationQueueItem(id: ConversationItemID(rawValue: UUID().uuidString), commandID: commandID, text: text, position: sessions[id]!.queued.count)
            sessions[id]!.queued.append(item)
            if sessions[id]!.currentTurnID == nil { return try await drainQueue(id: id, commandID: commandID) }
            try await emitQueue(id: id); return try await applied(commandID, id: id)
        case .editQueued(let itemID, let text):
            guard let index = sessions[id]!.queued.firstIndex(where: { $0.id == itemID }) else { throw ConversationProviderError.rejected("queued item not found") }
            sessions[id]!.queued[index].text = text; try await emitQueue(id: id); return try await applied(commandID, id: id)
        case .cancelQueued(let itemID):
            guard let index = sessions[id]!.queued.firstIndex(where: { $0.id == itemID }) else { throw ConversationProviderError.rejected("queued item not found") }
            sessions[id]!.queued.remove(at: index); try await emitQueue(id: id); return try await applied(commandID, id: id)
        case .startTurn(let text, let model, let effort):
            if sessions[id]!.connection == nil {
                guard sessions[id]!.session.providerSessionID != nil else { throw ConversationProviderError.unavailable("Provider session cannot be resumed safely") }
                guard let adapter = adapters[sessions[id]!.session.provider] else { throw ConversationProviderError.unsupported("No adapter for provider") }
                try await attach(id: id, adapter: adapter)
            }
            return try await sendProvider(.startTurn(text: text, model: model ?? sessions[id]!.session.model, effort: effort ?? sessions[id]!.session.effort), commandID: commandID, id: id)
        case .steer(let text): return try await sendProvider(.steer(text: text), commandID: commandID, id: id)
        case .interrupt: return try await sendProvider(.interrupt, commandID: commandID, id: id)
        case .answerQuestion, .resolveApproval: return try await sendProvider(command, commandID: commandID, id: id)
        }
    }

    private func sendProvider(_ command: ConversationCommand, commandID: ConversationCommandID, id: ConversationID) async throws -> ConversationReceipt {
        guard let connection = sessions[id]?.connection else { throw ConversationProviderError.unavailable("provider connection is not ready") }
        if case .startTurn = command { sessions[id]!.dispatchingTurn = true; sessions[id]!.session.updatedAt = Date(); try persist(sessions[id]!) }
        try await connection.send(command)
        return try await applied(commandID, id: id)
    }

    private func drainQueue(id: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt {
        guard !sessions[id]!.queued.isEmpty else { return try await applied(commandID, id: id) }
        var item = sessions[id]!.queued[0]; item.isDelivering = true; sessions[id]!.queued[0] = item
        sessions[id]!.dispatchingTurn = true
        try persist(sessions[id]!)
        try await emitQueue(id: id)
        guard let connection = sessions[id]!.connection else { throw ConversationProviderError.unavailable("provider connection is not ready") }
        try await connection.send(.startTurn(text: item.text, model: sessions[id]!.session.model, effort: sessions[id]!.session.effort))
        sessions[id]!.queued.removeFirst()
        try persist(sessions[id]!)
        try await emitQueue(id: id)
        return try await applied(commandID, id: id)
    }

    private func applied(_ commandID: ConversationCommandID, id: ConversationID) async throws -> ConversationReceipt {
        let state = sessions[id]!.session
        let receipt = ConversationReceipt(id: commandID, sessionID: id, state: .applied, eventSequence: sessions[id]!.cursor, generation: state.generation)
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

    private func emitQueue(id: ConversationID) async throws { _ = try await appendEvent(id: id, kind: .queue, queue: sessions[id]!.queued) }

    private func appendEvent(id: ConversationID, kind: ConversationEventKind, turnID: ConversationTurnID? = nil, item: ConversationItem? = nil, request: ConversationRequest? = nil, queue: [ConversationQueueItem]? = nil, receipt: ConversationReceipt? = nil, state: String? = nil, rawPayload: ConversationJSONValue? = nil) async throws -> ConversationEvent {
        guard var current = sessions[id] else { throw ConversationBrokerError.sessionNotFound(id) }
        current.cursor += 1
        let event = ConversationEvent(sessionID: id, sequence: current.cursor, generation: current.session.generation, kind: kind, turnID: turnID, item: item, request: request, queue: queue, receipt: receipt, state: state, rawPayload: rawPayload)
        try await current.journal.append(event)
        sessions[id] = current
        broadcast(event)
        onChange?(id, event.sequence)
        if current.cursor % ConversationCursor(snapshotInterval) == 0 { try await writeSnapshot(id: id) }
        return event
    }

    private func writeSnapshot(id: ConversationID) async throws {
        guard let state = sessions[id] else { return }
        let snapshot = ConversationSnapshot(session: state.session, cursor: state.cursor, generation: state.session.generation, items: state.items, pendingRequests: state.pendingRequests, queued: state.queued, receipts: Array(state.receipts.suffix(64)), activeTurnID: state.currentTurnID, isTurnRunning: state.currentTurnID != nil || state.dispatchingTurn, capabilities: state.capabilities)
        try await state.journal.write(snapshot: snapshot)
    }

    private func attach(id: ConversationID, adapter: any ConversationProviderAdapter) async throws {
        guard let state = sessions[id] else { throw ConversationBrokerError.sessionNotFound(id) }
        let connection = try await adapter.open(session: state.session, target: state.target)
        sessions[id]!.connection = connection
        if let nativeID = await connection.providerSessionID() { sessions[id]!.session.providerSessionID = nativeID }
        if let capabilities = await connection.capabilities() { sessions[id]!.capabilities = capabilities }
        sessions[id]!.session.state = .ready
        try persist(sessions[id]!)
        let task = Task { [weak self] in
            do {
                for try await event in connection.events { await self?.ingest(event, id: id) }
                await self?.markProviderRestarted(id: id, reason: "provider stream ended")
            } catch { await self?.markProviderRestarted(id: id, reason: error.localizedDescription) }
        }
        sessions[id]!.eventTask = task
    }

    private func ingest(_ providerEvent: ConversationProviderEvent, id: ConversationID) async {
        guard var state = sessions[id] else { return }
        var item: ConversationItem?
        var normalizedRequest: ConversationRequest?
        var didFinishTurn = false
        if providerEvent.kind == .item {
            let itemID = providerEvent.itemID ?? ConversationItemID(rawValue: UUID().uuidString)
            item = ConversationItem(id: itemID, sequence: state.cursor + 1, turnID: providerEvent.turnID, kind: providerEvent.itemKind ?? .unknown("provider"), role: providerEvent.role, text: providerEvent.text, tool: providerEvent.tool, plan: providerEvent.plan, diff: providerEvent.diff, artifact: providerEvent.artifact, usage: providerEvent.usage, rawPayload: providerEvent.rawPayload)
            if let index = state.items.firstIndex(where: { $0.id == itemID }) { state.items[index] = item! } else { state.items.append(item!) }
        } else if case .unknown(let unknownKind) = providerEvent.kind, providerEvent.rawPayload != nil {
            let itemID = providerEvent.itemID ?? ConversationItemID(rawValue: "unknown:\(state.cursor + 1)")
            item = ConversationItem(id: itemID, sequence: state.cursor + 1, turnID: providerEvent.turnID, kind: .unknown(unknownKind), role: providerEvent.role, text: providerEvent.text, rawPayload: providerEvent.rawPayload)
            state.items.append(item!)
        }
        if let request = providerEvent.request {
            normalizedRequest = ConversationRequest(id: request.id, turnID: request.turnID, generation: state.session.generation, kind: request.kind, state: request.state, approval: request.approval, question: request.question, rawPayload: request.rawPayload)
            if let index = state.pendingRequests.firstIndex(where: { $0.id == request.id }) { state.pendingRequests[index] = normalizedRequest! } else if normalizedRequest!.state == .pending { state.pendingRequests.append(normalizedRequest!) }
        }
        if providerEvent.kind == .turn || providerEvent.kind == .run {
            if let stateLabel = providerEvent.state, ["completed", "succeeded", "failed", "stopped", "cancelled", "idle"].contains(stateLabel) { state.currentTurnID = nil; state.dispatchingTurn = false; didFinishTurn = true }
            else if providerEvent.turnID != nil { state.currentTurnID = providerEvent.turnID; state.dispatchingTurn = false }
        }
        sessions[id] = state
        do { _ = try await appendEvent(id: id, kind: providerEvent.kind, turnID: providerEvent.turnID, item: item, request: normalizedRequest, state: providerEvent.state, rawPayload: providerEvent.rawPayload) }
        catch { await markProviderRestarted(id: id, reason: error.localizedDescription); return }
        if didFinishTurn, sessions[id]!.currentTurnID == nil, !sessions[id]!.queued.isEmpty, !sessions[id]!.queued[0].isDelivering { let command = sessions[id]!.queued[0].commandID; _ = try? await drainQueue(id: id, commandID: command) }
    }

    private func markProviderRestarted(id: ConversationID, reason: String) async {
        guard sessions[id] != nil else { return }
        sessions[id]!.connection = nil
        sessions[id]!.eventTask = nil
        sessions[id]!.session.generation = UUID().uuidString
        sessions[id]!.session.state = .stopped
        sessions[id]!.session.updatedAt = Date()
        sessions[id]!.pendingRequests = sessions[id]!.pendingRequests.map { ConversationRequest(id: $0.id, turnID: $0.turnID, generation: $0.generation, kind: $0.kind, state: .stale, approval: $0.approval, question: $0.question, rawPayload: $0.rawPayload) }
        try? persist(sessions[id]!)
        _ = try? await appendEvent(id: id, kind: .restarted, state: reason)
    }

    private func close(id: ConversationID) async {
        guard let connection = sessions[id]?.connection else { return }
        await connection.close()
        sessions[id]!.connection = nil
        sessions[id]!.eventTask?.cancel()
        sessions[id]!.eventTask = nil
    }

    private func broadcast(_ event: ConversationEvent) {
        guard var values = subscribers[event.sessionID] else { return }
        for (id, continuation) in values {
            let result = continuation.yield(event)
            if case .dropped = result { continuation.finish(throwing: ConversationBrokerError.eventStreamOverflow); values.removeValue(forKey: id) }
        }
        subscribers[event.sessionID] = values
    }

    private func removeSubscriber(sessionID: ConversationID, id: UUID) { subscribers[sessionID]?.removeValue(forKey: id) }

    private func persist(_ state: SessionState) throws {
        let record = SessionRecord(session: state.session, target: state.target)
        let data = try encoder.encode(record)
        let url = directory.appendingPathComponent(state.session.id.rawValue, isDirectory: true).appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: Int(0o700)])
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: url.path)
    }

    private func persistCreationReservations() throws {
        let url = directory.appendingPathComponent("creation-reservations.json")
        let data = try encoder.encode(creationReservations.mapValues(\.rawValue))
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: url.path)
    }

    private func loadCreationReservations() throws {
        let url = directory.appendingPathComponent("creation-reservations.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        creationReservations = raw.reduce(into: [:]) { result, pair in result[ConversationCommandID(rawValue: pair.key)] = ConversationID(rawValue: pair.value) }
    }

    private func loadPersistedSessions() throws {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let decoder = JSONDecoder()
        for child in directories {
            let url = child.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let record: SessionRecord
            do { record = try decoder.decode(SessionRecord.self, from: data) } catch { throw ConversationJournalError.corruptSession(url.path) }
            let journal = try ConversationJournal(directory: child)
            let snapshotURL = child.appendingPathComponent("snapshot.json")
            let snapshot = (try? Data(contentsOf: snapshotURL)).flatMap { try? decoder.decode(ConversationSnapshot.self, from: $0) }
            let capabilities = adapters[record.session.provider]?.capabilities ?? ConversationCapabilities(protocolVersion: "unknown", supportsResume: false)
            var state = SessionState(session: record.session, target: record.target, journal: journal, capabilities: capabilities, items: snapshot?.items ?? [], pendingRequests: snapshot?.pendingRequests ?? [], queued: snapshot?.queued ?? [], receipts: snapshot?.receipts ?? [], cursor: snapshot?.cursor ?? 0, currentTurnID: snapshot?.activeTurnID, dispatchingTurn: snapshot?.isTurnRunning ?? false, connection: nil, eventTask: nil)
            let after = snapshot?.cursor ?? 0
            let events = try decodeDurableEvents(at: child.appendingPathComponent("events.jsonl"))
            for event in events where event.sequence > after { apply(event, to: &state) }
            if let last = events.last { state.cursor = last.sequence }
            sessions[record.session.id] = state
        }
    }

    private func decodeDurableEvents(at url: URL) throws -> [ConversationEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return try data.split(separator: 10, omittingEmptySubsequences: true).compactMap { try decoder.decode(ConversationEvent.self, from: Data($0)) }
    }

    private func apply(_ event: ConversationEvent, to state: inout SessionState) {
        switch event.kind {
        case .item:
            if let item = event.item { if let index = state.items.firstIndex(where: { $0.id == item.id }) { state.items[index] = item } else { state.items.append(item) } }
        case .request:
            if let request = event.request { if let index = state.pendingRequests.firstIndex(where: { $0.id == request.id }) { state.pendingRequests[index] = request } else if request.state == .pending { state.pendingRequests.append(request) } }
        case .queue:
            state.queued = event.queue ?? []
        case .receipt:
            if let receipt = event.receipt { if let index = state.receipts.firstIndex(where: { $0.id == receipt.id }) { state.receipts[index] = receipt } else { state.receipts.append(receipt) } }
        case .turn, .run:
            if let turnID = event.turnID, event.state == "running" { state.currentTurnID = turnID; state.dispatchingTurn = false }
            if ["completed", "succeeded", "failed", "stopped", "cancelled", "idle"].contains(event.state ?? "") { state.currentTurnID = nil; state.dispatchingTurn = false }
        case .restarted:
            state.session.generation = event.generation; state.session.state = .stopped; state.currentTurnID = nil; state.dispatchingTurn = false
            state.pendingRequests = state.pendingRequests.map { request in var copy = request; copy.state = .stale; return copy }
        case .unknown:
            break
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

    public var description: String { switch self { case .sessionNotFound(let id): "session not found: \(id.rawValue)"; case .eventTooLarge(let cursor): "event too large at cursor \(cursor)"; case .eventStreamOverflow: "event stream overflow; snapshot and replay required"; case .providerRestarted(let value): "provider restarted: \(value)" } }
}
