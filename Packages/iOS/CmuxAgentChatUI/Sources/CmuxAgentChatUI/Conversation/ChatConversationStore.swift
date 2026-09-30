import CmuxAgentChat
import Foundation
import Observation

/// State for the native conversation surface.
///
/// The store only speaks ``ChatEventSource``. ACP, the existing terminal
/// transcript source, and a future hosted provider can therefore share the
/// same session picker, history cursor, optimistic send, and reconnect logic.
@MainActor
@Observable
public final class ChatConversationStore {
    /// Lifecycle of the provider connection.
    public enum ConnectionState: Equatable, Sendable {
        case idle
        case loading
        case connected
        case failed(String)
    }

    /// The backend seam used by this store.
    public let source: any ChatEventSource

    /// Optional workspace scope supplied to the provider.
    public let workspaceID: String?

    /// Current session list, ordered by the provider's preference.
    public private(set) var sessions: [ChatSessionDescriptor] = []

    /// Currently selected conversation.
    public private(set) var selectedSessionID: String?

    /// Loaded transcript messages, oldest first.
    public private(set) var messages: [ChatMessage] = []

    /// A live prose preview that has not yet become a committed message.
    public private(set) var streamingMessage: ChatMessage?

    /// Current connection state.
    public private(set) var connectionState: ConnectionState = .idle

    /// True while an older history page is being fetched.
    public private(set) var isLoadingOlder = false

    /// Whether the provider reports history before the loaded page.
    public private(set) var hasMoreHistory = false

    /// True when the selected agent is working.
    public private(set) var isWorking = false

    /// A send operation is waiting for the provider to accept it.
    public private(set) var isSending = false

    /// Local echo ids awaiting provider acknowledgement.
    public private(set) var pendingMessageIDs: Set<String> = []

    /// A user-readable error for the current surface.
    public private(set) var errorMessage: String?

    /// Changes whenever the rendered transcript changes, including streaming
    /// prose. The view uses it to keep the bottom anchor stable without
    /// comparing every message payload on every frame.
    public private(set) var renderRevision = 0

    private let initialPageSize = 80
    private let olderPageSize = 60
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = UUID()

    public init(source: any ChatEventSource, workspaceID: String? = nil) {
        self.source = source
        self.workspaceID = workspaceID
    }

    deinit {
        lifecycleTask?.cancel()
        eventsTask?.cancel()
    }

    /// Starts loading sessions. Calling this more than once is idempotent.
    public func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            await self?.loadInitialState()
        }
    }

    /// Stops network work while preserving the last rendered state.
    public func stop() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Reloads the session picker and keeps the current selection when it is
    /// still present.
    public func reloadSessions() {
        Task { [weak self] in
            await self?.loadSessions(keepSelection: true)
        }
    }

    /// Selects a conversation and loads its newest history page.
    public func select(sessionID: String) {
        guard selectedSessionID != sessionID || messages.isEmpty else { return }
        Task { [weak self] in
            await self?.activate(sessionID: sessionID)
        }
    }

    /// Creates a provider conversation and selects it.
    public func createSession(harness: String? = nil, workingDirectory: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                connectionState = .loading
                let sessionID = try await source.createSession(
                    harness: harness,
                    workingDirectory: workingDirectory
                )
                try Task.checkCancellation()
                await loadSessions(keepSelection: false)
                await activate(sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                connectionState = .failed(Self.message(for: error))
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Sends text after adding an immediate iMessage-style local echo.
    public func send(text: String, attachments: [ChatOutboundAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID = selectedSessionID else { return }

        let localID = "local-\(UUID().uuidString)"
        let nextSeq = (messages.last?.seq ?? 0) + 1
        messages.append(
            ChatMessage(
                id: localID,
                seq: nextSeq,
                role: .user,
                timestamp: Date(),
                kind: .prose(ChatProse(text: text))
            )
        )
        pendingMessageIDs.insert(localID)
        isSending = true
        errorMessage = nil
        markTranscriptChanged()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await source.send(text: text, attachments: attachments, sessionID: sessionID)
                try Task.checkCancellation()
                pendingMessageIDs.remove(localID)
                isSending = false
            } catch is CancellationError {
                return
            } catch {
                messages.removeAll { $0.id == localID }
                pendingMessageIDs.remove(localID)
                isSending = false
                errorMessage = Self.message(for: error)
                markTranscriptChanged()
            }
        }
    }

    /// Requests a soft interrupt from the provider.
    public func cancel() {
        guard let sessionID = selectedSessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await source.interrupt(sessionID: sessionID, hard: false)
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Answers an actionable provider request by display index.
    public func answer(optionIndex: Int) {
        guard let sessionID = selectedSessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Prepends one history page while preserving the current scroll anchor.
    public func loadOlder() {
        guard !isLoadingOlder,
              hasMoreHistory,
              let sessionID = selectedSessionID,
              let firstSeq = messages.first?.seq else { return }
        isLoadingOlder = true
        let generation = selectionGeneration
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingOlder = false }
            do {
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: firstSeq,
                    limit: olderPageSize
                )
                try Task.checkCancellation()
                guard generation == selectionGeneration,
                      sessionID == selectedSessionID else { return }
                messages = merge(page.messages, with: messages)
                hasMoreHistory = page.hasMore
                markTranscriptChanged()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Includes the uncommitted streaming preview after the authoritative
    /// message list so the renderer never loses live output.
    public var visibleMessages: [ChatMessage] {
        guard let streamingMessage else { return messages }
        guard !messages.contains(where: { $0.id == streamingMessage.id }) else { return messages }
        return messages + [streamingMessage]
    }

    private func loadInitialState() async {
        connectionState = .loading
        await loadSessions(keepSelection: false)
        guard !Task.isCancelled else { return }
        if let sessionID = ChatSessionDescriptor.openable(sessions).first?.id {
            await activate(sessionID: sessionID)
        } else {
            connectionState = .connected
        }
    }

    private func loadSessions(keepSelection: Bool) async {
        do {
            let loaded = try await source.sessions(workspaceID: workspaceID)
            try Task.checkCancellation()
            sessions = loaded
            if keepSelection,
               let selectedSessionID,
               let descriptor = loaded.first(where: { $0.id == selectedSessionID }) {
                isWorking = descriptor.state.isWorking
            }
        } catch is CancellationError {
            return
        } catch {
            connectionState = .failed(Self.message(for: error))
            errorMessage = Self.message(for: error)
        }
    }

    private func activate(sessionID: String) async {
        let generation = UUID()
        selectionGeneration = generation
        eventsTask?.cancel()
        eventsTask = nil
        selectedSessionID = sessionID
        messages = []
        streamingMessage = nil
        hasMoreHistory = false
        isWorking = false
        errorMessage = nil
        connectionState = .loading
        markTranscriptChanged()

        do {
            let page = try await source.history(
                sessionID: sessionID,
                beforeSeq: nil,
                limit: initialPageSize
            )
            try Task.checkCancellation()
            guard generation == selectionGeneration else { return }
            messages = deduplicate(page.messages)
            hasMoreHistory = page.hasMore
            if let descriptor = sessions.first(where: { $0.id == sessionID }) {
                isWorking = descriptor.state.isWorking
            } else if let descriptor = try? await source.session(sessionID: sessionID) {
                upsertSession(descriptor)
                isWorking = descriptor.state.isWorking
            }
            connectionState = .connected
            markTranscriptChanged()
            eventsTask = Task { [weak self, source] in
                let stream = await source.events(sessionID: sessionID)
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.receive(event, sessionID: sessionID, generation: generation)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == selectionGeneration else { return }
            connectionState = .failed(Self.message(for: error))
            errorMessage = Self.message(for: error)
        }
    }

    private func receive(
        _ event: ChatSessionEvent,
        sessionID: String,
        generation: UUID
    ) async {
        guard generation == selectionGeneration, sessionID == selectedSessionID else { return }
        switch event {
        case .appended(let incoming), .updated(let incoming):
            messages = merge(messages, with: incoming)
            streamingMessage = nil
            markTranscriptChanged()
        case .stateChanged(let state):
            isWorking = state.isWorking
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index] = sessions[index].withState(state)
            }
        case .descriptorChanged(let descriptor):
            upsertSession(descriptor)
            isWorking = descriptor.state.isWorking
        case .sessionRemoved:
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index] = sessions[index].withState(.ended)
            }
            isWorking = false
        case .streamingProse(let message):
            streamingMessage = message
            markTranscriptChanged()
        case .reset:
            await reloadSelectedHistory(generation: generation)
        case .terminalBlocks, .unknown:
            break
        }
    }

    private func reloadSelectedHistory(generation: UUID) async {
        guard let sessionID = selectedSessionID else { return }
        do {
            let page = try await source.history(sessionID: sessionID, beforeSeq: nil, limit: initialPageSize)
            guard generation == selectionGeneration else { return }
            messages = deduplicate(page.messages)
            hasMoreHistory = page.hasMore
            streamingMessage = nil
            markTranscriptChanged()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func upsertSession(_ descriptor: ChatSessionDescriptor) {
        if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
            sessions[index] = descriptor
        } else {
            sessions.append(descriptor)
        }
    }

    private func markTranscriptChanged() {
        renderRevision &+= 1
    }

    private func deduplicate(_ values: [ChatMessage]) -> [ChatMessage] {
        merge([], with: values)
    }

    private func merge(_ existing: [ChatMessage], with incoming: [ChatMessage]) -> [ChatMessage] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for message in incoming {
            if message.role == .user,
               let local = existing.first(where: {
                   $0.id.hasPrefix("local-")
                       && $0.role == .user
                       && $0.kind == message.kind
               }) {
                byID.removeValue(forKey: local.id)
                pendingMessageIDs.remove(local.id)
            }
            byID[message.id] = message
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            return lhs.id < rhs.id
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private extension ChatAgentState {
    var isWorking: Bool {
        switch self {
        case .working, .needsInput: return true
        case .idle, .ended: return false
        }
    }
}
