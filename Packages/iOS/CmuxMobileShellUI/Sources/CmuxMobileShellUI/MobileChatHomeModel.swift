import CmuxAgentChat
import CmuxMobileShell
import Foundation
import Observation

/// Main-actor state and transport coordinator for the native Chat surface.
@MainActor
@Observable
final class MobileChatHomeModel {
    private(set) var sessions: [ChatSessionDescriptor] = []
    private(set) var messagesBySessionID: [String: [ChatMessage]] = [:]
    private(set) var streamingMessageBySessionID: [String: ChatMessage] = [:]
    private(set) var errorMessage: String?
    private(set) var isLoadingSessions = false
    private(set) var loadingSessionIDs: Set<String> = []

    private var source: MobileChatEventSource?
    private var sessionEventsTask: Task<Void, Never>?
    private var conversationTasks: [String: Task<Void, Never>] = [:]

    nonisolated deinit {
        sessionEventsTask?.cancel()
        conversationTasks.values.forEach { $0.cancel() }
    }

    /// Loads the current Mac's chat roster and starts the roster event stream.
    func refresh(using store: CMUXMobileShellStore) async {
        sessionEventsTask?.cancel()
        sessionEventsTask = nil
        source = store.makeChatEventSource()
        guard let source else {
            sessions = []
            errorMessage = store.connectionState == .connected
                ? "Chat is unavailable on this computer."
                : "Connect a computer to see your chats."
            isLoadingSessions = false
            return
        }

        isLoadingSessions = true
        do {
            let loaded = try await source.sessions(workspaceID: nil)
            sessions = Self.sortedSessions(loaded)
            errorMessage = nil
            startSessionEvents(from: source)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Chats could not be loaded."
        }
        isLoadingSessions = false
    }

    /// Loads one transcript and keeps it current while the conversation is open.
    func open(sessionID: String) {
        guard let source else { return }
        conversationTasks[sessionID]?.cancel()
        loadingSessionIDs.insert(sessionID)
        conversationTasks[sessionID] = Task { [weak self] in
            do {
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: nil,
                    limit: 200
                )
                guard !Task.isCancelled else { return }
                self?.messagesBySessionID[sessionID] = page.messages
                self?.loadingSessionIDs.remove(sessionID)
                let events = await source.events(sessionID: sessionID)
                for await event in events {
                    guard !Task.isCancelled else { return }
                    self?.apply(event, to: sessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.loadingSessionIDs.remove(sessionID)
                self?.errorMessage = "This chat could not be opened."
            }
        }
    }

    /// Stops work associated with one conversation when its destination closes.
    func close(sessionID: String) {
        conversationTasks[sessionID]?.cancel()
        conversationTasks[sessionID] = nil
        streamingMessageBySessionID[sessionID] = nil
    }

    /// Sends a prompt to an existing agent session.
    func send(_ text: String, to sessionID: String) async -> Bool {
        guard let source else {
            errorMessage = "Connect a computer before sending a message."
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var transcript = messagesBySessionID[sessionID, default: []]
        let nextSeq = transcript.map(\.seq).max().map { $0 + 1 } ?? 0
        transcript.append(ChatMessage(
            id: "local-\(UUID().uuidString)",
            seq: nextSeq,
            role: .user,
            timestamp: Date(),
            kind: .prose(ChatProse(text: trimmed))
        ))
        messagesBySessionID[sessionID] = transcript
        do {
            try await source.send(text: trimmed, attachments: [], sessionID: sessionID)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = "Your message could not be sent."
            return false
        }
    }

    /// Answers an in-transcript question or permission request.
    func answer(optionIndex: Int, in sessionID: String) async {
        guard let source else { return }
        do {
            try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
        } catch {
            errorMessage = "That choice could not be sent."
        }
    }

    /// Interrupts a working agent turn.
    func interrupt(sessionID: String) async {
        guard let source else { return }
        do {
            try await source.interrupt(sessionID: sessionID, hard: false)
        } catch {
            errorMessage = "The agent could not be interrupted."
        }
    }

    /// Returns the transcript rows for a session, including a live prose preview.
    func messages(for sessionID: String) -> [ChatMessage] {
        var result = messagesBySessionID[sessionID, default: []]
        if let streaming = streamingMessageBySessionID[sessionID] {
            result.append(streaming)
        }
        return result
    }

    /// Inserts a locally-created session so the list has immediate feedback.
    func insertPlaceholder(for provider: MobileChatProvider, title: String?) {
        let id = "pending-\(UUID().uuidString)"
        sessions.insert(
            ChatSessionDescriptor(
                id: id,
                agentKind: provider.chatAgentKind,
                title: title,
                state: .working(since: Date()),
                lastActivityAt: Date()
            ),
            at: 0
        )
    }

    /// Seeds the deterministic UI preview without touching a transport.
    func loadPreview() {
        let now = Date()
        sessions = [
            ChatSessionDescriptor(
                id: "preview-codex",
                agentKind: .codex,
                title: "Review the mobile navigation",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-420)
            ),
            ChatSessionDescriptor(
                id: "preview-claude",
                agentKind: .claude,
                title: "Fix the release checklist",
                state: .working(since: now.addingTimeInterval(-36)),
                lastActivityAt: now.addingTimeInterval(-36)
            ),
            ChatSessionDescriptor(
                id: "preview-opencode",
                agentKind: .other("opencode"),
                title: "Build a small SwiftUI prototype",
                state: .needsInput(since: now.addingTimeInterval(-90)),
                lastActivityAt: now.addingTimeInterval(-90)
            ),
        ]
        messagesBySessionID["preview-codex"] = Self.previewMessages(now: now)
        errorMessage = nil
        isLoadingSessions = false
    }

    private func startSessionEvents(from source: MobileChatEventSource) {
        sessionEventsTask = Task { [weak self] in
            let events = await source.sessionEvents()
            for await frame in events {
                guard !Task.isCancelled else { return }
                self?.apply(frame.event, to: frame.sessionID)
            }
        }
    }

    private func apply(_ event: ChatSessionEvent, to sessionID: String) {
        switch event {
        case .appended(let messages), .updated(let messages):
            var transcript = messagesBySessionID[sessionID, default: []]
            for message in messages {
                if let index = transcript.firstIndex(where: { $0.id == message.id }) {
                    transcript[index] = message
                } else {
                    transcript.append(message)
                }
            }
            messagesBySessionID[sessionID] = transcript.sorted { $0.seq < $1.seq }
            streamingMessageBySessionID[sessionID] = nil
        case .streamingProse(let message):
            if let message { streamingMessageBySessionID[sessionID] = message }
            else { streamingMessageBySessionID[sessionID] = nil }
        case .stateChanged(let state):
            updateSession(id: sessionID) { $0.withState(state) }
        case .descriptorChanged(let descriptor):
            upsertSession(descriptor)
        case .sessionRemoved:
            sessions.removeAll { $0.id == sessionID }
            messagesBySessionID[sessionID] = nil
            streamingMessageBySessionID[sessionID] = nil
        case .reset:
            messagesBySessionID[sessionID] = []
            streamingMessageBySessionID[sessionID] = nil
        case .terminalBlocks, .unknown:
            break
        }
    }

    private func upsertSession(_ descriptor: ChatSessionDescriptor) {
        if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
            sessions[index] = descriptor
        } else {
            sessions.append(descriptor)
        }
        sessions = Self.sortedSessions(sessions)
    }

    private func updateSession(
        id: String,
        transform: (ChatSessionDescriptor) -> ChatSessionDescriptor
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index] = transform(sessions[index])
    }

    private static func sortedSessions(_ sessions: [ChatSessionDescriptor]) -> [ChatSessionDescriptor] {
        sessions.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    private static func previewMessages(now: Date) -> [ChatMessage] {
        [
            ChatMessage(
                id: "preview-user",
                seq: 0,
                role: .user,
                timestamp: now.addingTimeInterval(-380),
                kind: .prose(ChatProse(text: "Can you make the new mobile navigation feel native?"))
            ),
            ChatMessage(
                id: "preview-tool",
                seq: 1,
                role: .agent,
                timestamp: now.addingTimeInterval(-360),
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "Read CMUXMobileRootView.swift",
                    status: .succeeded
                ))
            ),
            ChatMessage(
                id: "preview-agent",
                seq: 2,
                role: .agent,
                timestamp: now.addingTimeInterval(-330),
                kind: .prose(ChatProse(text: "I found the existing shell entry point. I’ll keep the connection lifecycle and replace the session UI with a focused chat surface."))
            ),
        ]
    }
}
