import CmuxAgentReplica
import CmuxAgentWire
import Foundation

extension AgentSyncEngine {
    func flushQueuedTickets() async throws {
        let queued = conversations.values
            .flatMap(\.sendTickets)
            .filter { ticket in
                if case .queuedLocal = ticket.state { return true }
                return false
            }
            .sorted { $0.createdAt < $1.createdAt }
        for ticket in queued {
            try Task.checkCancellation()
            try await submitQueuedTicket(ticket, origin: .resync)
        }
    }

    func submitQueuedTicket(_ ticket: SendTicket, origin: DeltaOrigin) async throws {
        guard let conversation = conversations[ticket.sessionID] else { return }
        let params = GuiSendParams(sessionID: ticket.sessionID, ticketID: ticket.id.uuidString, text: ticket.text)
        do {
            let data = try await request(method: GuiWireMethod.send, params: params)
            let result = try decode(GuiSendResult.self, from: data)
            let nextState: SendTicketState = result.accepted ? .acceptedByMac : .failed(code: "send_rejected")
            conversation.apply(.sendTicketChanged(ticket.withState(nextState)), origin: origin)
        } catch AgentSyncError.wire(let wireError) {
            conversation.apply(
                .sendTicketChanged(ticket.withState(.failed(code: wireError.code.rawValue))),
                origin: origin
            )
        }
    }

    func requestHello() async throws -> GuiHelloResult {
        try await request(
            method: GuiWireMethod.hello,
            params: GuiHelloParams(protocolMin: 1, protocolMax: 1, clientCaps: ["ios.agent_gui.sync.v1"])
        )
    }

    func requestSessions() async throws -> GuiSessionsResult {
        try await request(method: GuiWireMethod.sessions, params: GuiSessionsParams())
    }

    func entries(
        sessionID: AgentSessionID,
        journalID: JournalID?,
        beforeSeq: EntrySeq?,
        afterSeq: EntrySeq?,
        anchor: GuiEntriesAnchor? = nil,
        cursor: JournalCursor? = nil,
        limit: Int
    ) async throws -> GuiEntriesResult {
        try await request(
            method: GuiWireMethod.entries,
            params: GuiEntriesParams(
                sessionID: sessionID,
                journalID: journalID,
                beforeSeq: beforeSeq,
                afterSeq: afterSeq,
                anchor: anchor,
                cursor: cursor,
                limit: limit
            )
        )
    }

    func cursorEntries(
        sessionID: AgentSessionID,
        journalID: JournalID?,
        anchor: GuiEntriesAnchor,
        cursor: JournalCursor?,
        limit: Int
    ) async throws -> GuiEntriesResult {
        try await entries(
            sessionID: sessionID,
            journalID: journalID,
            beforeSeq: nil,
            afterSeq: nil,
            anchor: anchor,
            cursor: cursor,
            limit: limit
        )
    }

    func request<Response: Decodable, Params: Encodable>(
        method: String,
        params: Params
    ) async throws -> Response {
        let data = try await request(method: method, params: params)
        return try decode(Response.self, from: data)
    }

    func request<Params: Encodable>(method: String, params: Params) async throws -> Data {
        do {
            return try await transport.request(method: method, params: encoder.encode(params))
        } catch let error as GuiWireError {
            throw AgentSyncError.wire(error)
        } catch let error as AgentSyncError {
            throw error
        } catch {
            throw AgentSyncError.transport(Self.errorDescription(error))
        }
    }

    func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AgentSyncError.malformedResponse
        }
    }

    func desiredTopics() -> [String] {
        ([GuiWireTopic.sessions] + conversations.keys
            .sorted { $0.rawValue < $1.rawValue }
            .map { GuiWireTopic.journal(sessionID: $0) })
    }

    func sessionID(for event: GuiEventFrame, topic: String) -> AgentSessionID? {
        if let sessionID = event.sessionID {
            return sessionID
        }
        let prefix = GuiWireTopic.journalPrefix
        guard topic.hasPrefix(prefix) else { return nil }
        return AgentSessionID(rawValue: String(topic.dropFirst(prefix.count)))
    }

    func retryDelayMilliseconds(attempt: Int) -> Int {
        let exponent = max(0, attempt - 1)
        let base = min(16_000, 500 * (1 << min(exponent, 6)))
        let fraction = min(0.2, max(-0.2, jitter.retryJitterFraction()))
        return max(0, Int((Double(base) * (1 + fraction)).rounded()))
    }

    static func errorDescription(_ error: any Error) -> String {
        if case AgentSyncError.wire(let wire) = error {
            return wire.code.rawValue
        }
        if case AgentSyncError.transport(let message) = error {
            return message
        }
        if case AgentSyncError.offline = error {
            return "offline"
        }
        if case AgentSyncError.conversationNotOpen = error {
            return "conversation_not_open"
        }
        if case AgentSyncError.malformedResponse = error {
            return "malformed_response"
        }
        return String(describing: error)
    }
}

private extension SendTicket {
    func withState(_ state: SendTicketState) -> SendTicket {
        SendTicket(
            id: id,
            sessionID: sessionID,
            text: text,
            attachmentCount: attachmentCount,
            state: state,
            createdAt: createdAt
        )
    }
}
