import CmuxAgentChat
import Foundation

struct GlobalSearchTranscriptRouting: Sendable, Equatable {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let workspaceTitle: String
    let panelTitle: String
    let location: String
}

actor GlobalSearchTranscriptIndexer {
    static let messagesPerChunk = 50

    private let index: any SearchIndexWriting
    private let routing: @Sendable (String?, String?) async -> GlobalSearchTranscriptRouting?
    private let debounce: Duration
    private let clock: any Clock<Duration>

    private var sessions: [String: SessionState] = [:]
    private var sessionOrder: [String] = []
    private var flushTasks: [String: Task<Void, Never>] = [:]

    init(
        index: any SearchIndexWriting,
        routing: @escaping @Sendable (String?, String?) async -> GlobalSearchTranscriptRouting?,
        debounce: Duration = .milliseconds(500),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.index = index
        self.routing = routing
        self.debounce = debounce
        self.clock = clock
    }

    func ingest(sessionID: String, batch: AgentChatTranscriptTailer.Batch) async {
        let previousState = sessions[sessionID]
        if batch.didReset {
            sessions[sessionID] = nil
            flushTasks[sessionID]?.cancel()
            flushTasks[sessionID] = nil
            try? await index.deleteDocuments(
                idPrefix: GlobalSearchTranscriptDocuments.sessionDocumentPrefix(sessionID: sessionID)
            )
        }

        var state = sessions[sessionID] ?? SessionState(
            title: previousState?.title,
            workspaceID: previousState?.workspaceID,
            panelID: previousState?.panelID
        )
        if let title = Self.nonEmpty(batch.discoveredTitle) {
            state.title = title
        }
        let messages = batch.appended + batch.updated
        for message in messages {
            state.upsert(message: message)
        }
        sessions[sessionID] = state
        markRecentlyUsed(sessionID)
        await enforceChunkRetention(for: sessionID)
        enforceSessionRetention()
        scheduleFlush(sessionID: sessionID)
    }

    func updateSessionBinding(
        sessionID: String,
        workspaceID: String?,
        panelID: String?,
        title: String?
    ) {
        var state = sessions[sessionID] ?? SessionState()
        state.workspaceID = workspaceID
        state.panelID = panelID
        if let title = Self.nonEmpty(title) {
            state.title = title
        }
        sessions[sessionID] = state
        markRecentlyUsed(sessionID)
        enforceSessionRetention()
    }

    func flushNow(sessionID: String) async {
        flushTasks[sessionID]?.cancel()
        flushTasks[sessionID] = nil
        await flush(sessionID: sessionID)
    }

    private func scheduleFlush(sessionID: String) {
        flushTasks[sessionID]?.cancel()
        let debounce = debounce
        let clock = clock
        flushTasks[sessionID] = Task { [weak self] in
            do {
                // Cancellable debounce window; tests can pass `.zero`.
                try await clock.sleep(for: debounce)
            } catch {
                return
            }
            await self?.flush(sessionID: sessionID)
        }
    }

    private func flush(sessionID: String) async {
        flushTasks[sessionID] = nil
        guard var state = sessions[sessionID],
              !state.dirtyOrdinals.isEmpty else {
            return
        }
        guard let route = await routing(state.workspaceID, state.panelID) else {
            sessions[sessionID] = state
            return
        }

        let title = state.title ?? route.panelTitle
        let dirtyOrdinals = state.dirtyOrdinals.sorted()
        for ordinal in dirtyOrdinals {
            guard let chunk = state.chunks[ordinal] else {
                try? await index.deleteDocument(
                    id: GlobalSearchTranscriptDocuments.transcriptDocumentID(sessionID: sessionID, ordinal: ordinal)
                )
                try? await index.deleteDocument(
                    id: GlobalSearchTranscriptDocuments.commandDocumentID(sessionID: sessionID, ordinal: ordinal)
                )
                state.dirtyOrdinals.remove(ordinal)
                continue
            }

            let transcriptText = chunk.transcriptText
            if transcriptText.isEmpty {
                try? await index.deleteDocument(
                    id: GlobalSearchTranscriptDocuments.transcriptDocumentID(sessionID: sessionID, ordinal: ordinal)
                )
            } else {
                try? await index.upsert(GlobalSearchTranscriptDocuments.transcriptDocument(
                    sessionID: sessionID,
                    ordinal: ordinal,
                    routing: route,
                    title: title,
                    anchorSeq: chunk.firstSeq,
                    text: transcriptText
                ))
            }

            let commandText = chunk.commandText
            if commandText.isEmpty {
                try? await index.deleteDocument(
                    id: GlobalSearchTranscriptDocuments.commandDocumentID(sessionID: sessionID, ordinal: ordinal)
                )
            } else {
                try? await index.upsert(GlobalSearchTranscriptDocuments.commandDocument(
                    sessionID: sessionID,
                    ordinal: ordinal,
                    routing: route,
                    title: title,
                    anchorSeq: chunk.firstSeq,
                    text: commandText
                ))
            }
            state.dirtyOrdinals.remove(ordinal)
        }
        sessions[sessionID] = state
    }

    private func enforceChunkRetention(for sessionID: String) async {
        guard var state = sessions[sessionID] else { return }
        while state.chunks.count > GlobalSearchIndexingLimits.maxTranscriptChunksPerSession,
              let oldest = state.chunks.keys.min() {
            state.chunks[oldest] = nil
            state.dirtyOrdinals.remove(oldest)
            try? await index.deleteDocument(
                id: GlobalSearchTranscriptDocuments.transcriptDocumentID(sessionID: sessionID, ordinal: oldest)
            )
            try? await index.deleteDocument(
                id: GlobalSearchTranscriptDocuments.commandDocumentID(sessionID: sessionID, ordinal: oldest)
            )
        }
        sessions[sessionID] = state
    }

    private func enforceSessionRetention() {
        while sessionOrder.count > GlobalSearchIndexingLimits.maxTrackedTranscriptSessions {
            let evicted = sessionOrder.removeFirst()
            sessions[evicted] = nil
            flushTasks[evicted]?.cancel()
            flushTasks[evicted] = nil
        }
    }

    private func markRecentlyUsed(_ sessionID: String) {
        sessionOrder.removeAll { $0 == sessionID }
        sessionOrder.append(sessionID)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct SessionState {
    var title: String?
    var workspaceID: String?
    var panelID: String?
    var chunks: [Int: TranscriptChunkState] = [:]
    var dirtyOrdinals: Set<Int> = []

    mutating func upsert(message: ChatMessage) {
        let ordinal = message.seq / GlobalSearchTranscriptIndexer.messagesPerChunk
        var chunk = chunks[ordinal] ?? TranscriptChunkState()
        chunk.messages[message.seq] = IndexedMessageText(
            seq: message.seq,
            transcriptText: GlobalSearchTranscriptDocuments.transcriptText(for: message),
            commandText: GlobalSearchTranscriptDocuments.commandText(for: message)
        )
        chunks[ordinal] = chunk
        dirtyOrdinals.insert(ordinal)
    }
}

private struct TranscriptChunkState {
    var messages: [Int: IndexedMessageText] = [:]

    var firstSeq: Int {
        messages.keys.min() ?? 0
    }

    var transcriptText: String {
        GlobalSearchDocuments.cappedText(
            messages.values
            .sorted { $0.seq < $1.seq }
            .compactMap(\.transcriptText)
            .joined(separator: "\n\n"),
            limit: GlobalSearchIndexingLimits.maxTranscriptChunkCharacters
        )
    }

    var commandText: String {
        GlobalSearchDocuments.cappedText(
            messages.values
            .sorted { $0.seq < $1.seq }
            .compactMap(\.commandText)
            .joined(separator: "\n\n"),
            limit: GlobalSearchIndexingLimits.maxCommandChunkCharacters
        )
    }
}

private struct IndexedMessageText {
    let seq: Int
    let transcriptText: String?
    let commandText: String?
}
