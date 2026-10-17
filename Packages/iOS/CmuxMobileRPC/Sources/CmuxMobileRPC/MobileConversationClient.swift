public import CmuxConversation
public import Foundation

/// The native conversation client for one authenticated Mac and its workspaces.
/// Outbox files must be scoped by account and host identity by the composition root.
public actor MobileConversationClient: ConversationArtifactClient {
    private let rpc: MobileConversationRPC
    private let workspaceIDs: Set<String>
    private let outbox: MobileConversationOutbox
    private var sessionWorkspaces: [ConversationID: String] = [:]

    /// Creates a client without starting provider work or replaying pending commands.
    public init(connection: any MobileSyncing, workspaceIDs: Set<String>, outboxURL: URL) throws {
        self.rpc = MobileConversationRPC(connection: connection)
        self.workspaceIDs = workspaceIDs
        self.outbox = try MobileConversationOutbox(fileURL: outboxURL)
    }

    /// Uses a stable store when the underlying connection is replaced.
    public init(connection: any MobileSyncing, workspaceIDs: Set<String>, storage: MobileConversationStorage) {
        self.rpc = MobileConversationRPC(connection: connection)
        self.workspaceIDs = workspaceIDs
        self.outbox = storage.outbox
    }

    public func listSessions() async throws -> [ConversationSession] {
        var sessions: [ConversationSession] = []
        for workspaceID in workspaceIDs.sorted() {
            try Task.checkCancellation()
            let values: [ConversationSession] = try await rpc.call(
                "list", workspaceID: workspaceID, payload: EmptyQuery()
            )
            guard values.allSatisfy({ $0.workspaceID == workspaceID }) else {
                throw MobileConversationTransportError.invalidScope
            }
            sessions.append(contentsOf: values)
        }
        var known: [ConversationID: String] = [:]
        for session in sessions {
            guard known.updateValue(session.workspaceID, forKey: session.id) == nil else {
                throw MobileConversationTransportError.invalidResponse
            }
        }
        sessionWorkspaces = known
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession {
        guard workspaceIDs.contains(request.workspaceID) else {
            throw MobileConversationTransportError.invalidScope
        }
        let commandID = request.requestID ?? ConversationCommandID(rawValue: UUID().uuidString)
        let staged = ConversationCreateRequest(
            requestID: commandID, provider: request.provider, workspaceID: request.workspaceID,
            directory: request.directory, launchTarget: request.launchTarget, title: request.title
        )
        try await outbox.stage(
            commandID: commandID.rawValue,
            sessionID: "create:\(request.workspaceID)",
            command: Self.encode(staged)
        )
        let session: ConversationSession = try await rpc.call(
            "create", workspaceID: request.workspaceID, payload: staged
        )
        guard session.workspaceID == request.workspaceID else {
            throw MobileConversationTransportError.invalidScope
        }
        sessionWorkspaces[session.id] = session.workspaceID
        try await outbox.record(commandID: commandID.rawValue, receipt: Self.encode(session), settled: true)
        return session
    }

    public func snapshot(sessionID: ConversationID) async throws -> ConversationSnapshot {
        let workspaceID = try await workspace(for: sessionID)
        var snapshot: ConversationSnapshot = try await rpc.call(
            "snapshot", workspaceID: workspaceID, payload: ConversationSessionQuery(sessionID: sessionID)
        )
        guard snapshot.session.id == sessionID,
              snapshot.session.workspaceID == workspaceID,
              snapshot.session.generation == snapshot.generation,
              snapshot.receipts.allSatisfy({ $0.sessionID == sessionID }),
              snapshot.items.allSatisfy({ $0.sequence <= snapshot.cursor }),
              Set(snapshot.items.map(\.id)).count == snapshot.items.count else {
            throw MobileConversationTransportError.invalidResponse
        }
        // Read-only reconciliation. Absence of a receipt is not permission to
        // retry; delivery might have failed after the provider accepted it.
        let pending = await outbox.pending(sessionID: sessionID.rawValue)
        for entry in pending {
            let known = snapshot.receipts.first { $0.id.rawValue == entry.commandID }
            let receipt: ConversationReceipt?
            if let known {
                receipt = known
            } else {
                receipt = try await self.receipt(ConversationReceiptQuery(
                    sessionID: sessionID, commandID: .init(rawValue: entry.commandID)
                ))
            }
            let reconciled = receipt ?? ConversationReceipt(
                id: .init(rawValue: entry.commandID), sessionID: sessionID,
                state: .uncertain, reason: String(localized: "conversation.error.unconfirmed", defaultValue: "Delivery is unconfirmed. This command was not sent again.", bundle: .module),
                generation: snapshot.generation, createdAt: entry.createdAt
            )
            try await record(reconciled)
            if let index = snapshot.receipts.firstIndex(where: { $0.id == reconciled.id }) {
                snapshot.receipts[index] = reconciled
            } else {
                snapshot.receipts.append(reconciled)
            }
        }
        return snapshot
    }

    public func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent] {
        let workspaceID = try await workspace(for: sessionID)
        let events: [ConversationEvent] = try await rpc.call(
            "replay", workspaceID: workspaceID,
            payload: ConversationSessionQuery(sessionID: sessionID, after: after)
        )
        var cursor = after
        for event in events {
            guard event.sessionID == sessionID, cursor < .max, event.sequence == cursor + 1 else {
                throw MobileConversationTransportError.invalidResponse
            }
            cursor = event.sequence
            if let receipt = event.receipt {
                guard receipt.sessionID == sessionID else { throw MobileConversationTransportError.invalidResponse }
                try await record(receipt)
            }
        }
        return events
    }

    public func events(sessionID: ConversationID, after: ConversationCursor = 0) async -> AsyncThrowingStream<ConversationEvent, any Error> {
        let changes = await rpc.changes()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1_024)) { continuation in
            let task = Task {
                do {
                    var cursor = after
                    // Every hint invalidates the active projection: coalescing
                    // may replace its hint with one for another session.
                    for try await _ in changes {
                        while true {
                            try Task.checkCancellation()
                            let events = try await self.replay(sessionID: sessionID, after: cursor)
                            guard !events.isEmpty else { break }
                            for event in events {
                                switch continuation.yield(event) {
                                case .enqueued: cursor = event.sequence
                                case .dropped: throw MobileConversationTransportError.eventOverflow
                                case .terminated: return
                                @unknown default: throw MobileConversationTransportError.eventOverflow
                                }
                            }
                        }
                    }
                    throw MobileConversationTransportError.disconnected
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func execute(_ command: ConversationCommandEnvelope) async throws -> ConversationReceipt {
        let workspaceID = try await workspace(for: command.sessionID)
        try await outbox.stage(
            commandID: command.commandID.rawValue, sessionID: command.sessionID.rawValue,
            command: Self.encode(command)
        )
        let receipt: ConversationReceipt
        do {
            receipt = try await rpc.call("command", workspaceID: workspaceID, payload: command)
            guard receipt.id == command.commandID, receipt.sessionID == command.sessionID else {
                throw MobileConversationTransportError.invalidResponse
            }
        } catch {
            // Once staged, a failed round trip is ambiguous. Never synthesize a
            // rejection or redispatch it with a fresh command identity.
            let uncertain = ConversationReceipt(
                id: command.commandID, sessionID: command.sessionID, state: .uncertain,
                reason: String(localized: "conversation.error.reconcile", defaultValue: "Delivery is unconfirmed. Reconnect to check its status.", bundle: .module),
                generation: command.expectedGeneration ?? "unknown"
            )
            try await record(uncertain)
            return uncertain
        }
        try await record(receipt)
        return receipt
    }

    public func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt? {
        let workspaceID = try await workspace(for: query.sessionID)
        let value: ConversationReceipt? = try await rpc.call("receipt", workspaceID: workspaceID, payload: query)
        if let value {
            guard value.sessionID == query.sessionID, value.id == query.commandID else {
                throw MobileConversationTransportError.invalidResponse
            }
            try await record(value)
        }
        return value
    }

    public func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt? {
        try await receipt(ConversationReceiptQuery(sessionID: sessionID, commandID: commandID))
    }

    public func artifactChunk(_ query: ConversationArtifactQuery) async throws -> ConversationArtifactChunk {
        let workspaceID = try await workspace(for: query.sessionID)
        let value: ConversationArtifactChunk = try await rpc.call("artifact", workspaceID: workspaceID, payload: query)
        guard value.artifactID == query.artifactID, value.offset == query.offset,
              value.totalBytes <= 16_777_216, value.data.count <= 65_536,
              value.offset <= value.totalBytes, UInt64(value.data.count) <= value.totalBytes - value.offset,
              value.offset == 0 || value.sha256 == query.expectedSHA256,
              query.expectedSHA256 == nil || value.sha256 == query.expectedSHA256,
              value.sha256.utf8.count == 64,
              value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !value.data.isEmpty || value.offset == value.totalBytes else {
            throw MobileConversationTransportError.invalidResponse
        }
        return value
    }

    private func workspace(for sessionID: ConversationID) async throws -> String {
        if let workspaceID = sessionWorkspaces[sessionID], workspaceIDs.contains(workspaceID) { return workspaceID }
        _ = try await listSessions()
        guard let workspaceID = sessionWorkspaces[sessionID], workspaceIDs.contains(workspaceID) else {
            throw MobileConversationTransportError.invalidScope
        }
        return workspaceID
    }

    private func record(_ receipt: ConversationReceipt) async throws {
        try await outbox.record(
            commandID: receipt.id.rawValue, receipt: Self.encode(receipt),
            settled: receipt.state == .applied || receipt.state == .rejected
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private struct EmptyQuery: Codable, Sendable {}
}
