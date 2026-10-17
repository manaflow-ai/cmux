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
    private(set) var activeComputerID: String?

    private var source: MobileChatEventSource?
    private var sessionEventsTask: Task<Void, Never>?
    private var conversationTasks: [String: Task<Void, Never>] = [:]
    private var openSessionIDs: Set<String> = []
    private var pendingLocalMessages: [String: [ChatMessage]] = [:]
    private var refreshGeneration = UUID()

    isolated deinit {
        sessionEventsTask?.cancel()
        conversationTasks.values.forEach { $0.cancel() }
    }

    /// Loads the current Mac's chat roster and starts the roster event stream.
    func refresh(using store: CMUXMobileShellStore) async {
        let generation = UUID()
        refreshGeneration = generation
        let targetComputerID = store.connectedMacDeviceID
        if activeComputerID != targetComputerID {
            openSessionIDs.removeAll()
            messagesBySessionID.removeAll()
            streamingMessageBySessionID.removeAll()
            pendingLocalMessages.removeAll()
            loadingSessionIDs.removeAll()
            self.activeComputerID = targetComputerID
        }
        sessionEventsTask?.cancel()
        sessionEventsTask = nil
        conversationTasks.values.forEach { $0.cancel() }
        conversationTasks.removeAll()
        source = nil
        guard let nextSource = store.makeChatEventSource() else {
            guard refreshGeneration == generation else { return }
            sessions = []
            errorMessage = store.connectionState == .connected
                ? "Chat is unavailable on this computer."
                : "Connect a computer to see your chats."
            isLoadingSessions = false
            return
        }

        isLoadingSessions = true
        do {
            let loaded = try await nextSource.sessions(workspaceID: nil)
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            source = nextSource
            activeComputerID = targetComputerID
            sessions = Self.sortedSessions(loaded.filter(Self.isSupported))
            errorMessage = nil
            startSessionEvents(from: nextSource, generation: generation)
            for sessionID in openSessionIDs {
                open(sessionID: sessionID, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            errorMessage = "Chats could not be loaded."
        }
        guard refreshGeneration == generation else { return }
        isLoadingSessions = false
    }

    /// Loads one transcript and keeps it current while the conversation is open.
    func open(sessionID: String) {
        open(sessionID: sessionID, generation: refreshGeneration)
    }

    private func open(sessionID: String, generation: UUID) {
        openSessionIDs.insert(sessionID)
        guard let source else { return }
        conversationTasks[sessionID]?.cancel()
        loadingSessionIDs.insert(sessionID)
        conversationTasks[sessionID] = Task { [weak self] in
            do {
                // Register the live stream before taking the snapshot. The
                // source completes its server-side handshake before returning,
                // and the local stream buffers frames while history loads.
                let events = await source.events(sessionID: sessionID)
                let eventTask = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled,
                              self?.refreshGeneration == generation else { return }
                        self?.apply(event, to: sessionID)
                    }
                }
                defer { eventTask.cancel() }
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: nil,
                    limit: 200
                )
                guard !Task.isCancelled,
                      self?.refreshGeneration == generation else { return }
                if let self {
                    let local = self.pendingLocalMessages[sessionID, default: []]
                    let existing = self.messagesBySessionID[sessionID, default: []]
                    self.messagesBySessionID[sessionID] = Self.mergedMessages(
                        serverMessages: page.messages,
                        localMessages: existing + local
                    )
                }
                self?.loadingSessionIDs.remove(sessionID)
                await eventTask.value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                self?.loadingSessionIDs.remove(sessionID)
                self?.errorMessage = "This chat could not be opened."
            }
        }
    }

    /// Stops work associated with one conversation when its destination closes.
    func close(sessionID: String) {
        openSessionIDs.remove(sessionID)
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
        pendingLocalMessages[sessionID, default: []].append(transcript.last!)
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

    /// The last user-facing prose line shown under a recent chat title.
    func previewText(for sessionID: String) -> String? {
        for message in messages(for: sessionID).reversed() {
            guard case .prose(let prose) = message.kind else { continue }
            let text = prose.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
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
        messagesBySessionID = ["preview-codex": Self.previewMessages(now: now)]
        streamingMessageBySessionID = [:]
        errorMessage = nil
        isLoadingSessions = false
    }

    private func startSessionEvents(from source: MobileChatEventSource, generation: UUID) {
        sessionEventsTask = Task { [weak self] in
            let events = await source.sessionEvents()
            for await frame in events {
                guard !Task.isCancelled,
                      self?.refreshGeneration == generation else { return }
                self?.apply(frame.event, to: frame.sessionID)
            }
        }
    }

    private func apply(_ event: ChatSessionEvent, to sessionID: String) {
        switch event {
        case .appended(let messages), .updated(let messages):
            var transcript = messagesBySessionID[sessionID, default: []]
            for message in messages {
                if let localIndex = transcript.firstIndex(where: {
                    Self.isOptimisticMatch($0, serverMessage: message)
                }) {
                    transcript.remove(at: localIndex)
                }
                if let index = transcript.firstIndex(where: { $0.id == message.id }) {
                    transcript[index] = message
                } else {
                    transcript.append(message)
                }
                pendingLocalMessages[sessionID]?.removeAll {
                    Self.isOptimisticMatch($0, serverMessage: message)
                }
            }
            messagesBySessionID[sessionID] = transcript.sorted { $0.seq < $1.seq }
            streamingMessageBySessionID[sessionID] = nil
        case .streamingProse(let message):
            if let message { streamingMessageBySessionID[sessionID] = message }
            else { streamingMessageBySessionID[sessionID] = nil }
        case .stateChanged(let state):
            updateSession(id: sessionID) { descriptor in
                descriptor.withState(state, lastActivityAt: Date())
            }
        case .descriptorChanged(let descriptor):
            upsertSession(descriptor)
        case .sessionRemoved:
            sessions.removeAll { $0.id == sessionID }
            messagesBySessionID[sessionID] = nil
            streamingMessageBySessionID[sessionID] = nil
        case .reset:
            messagesBySessionID[sessionID] = []
            streamingMessageBySessionID[sessionID] = nil
            pendingLocalMessages[sessionID] = []
        case .terminalBlocks, .unknown:
            break
        }
    }

    private func upsertSession(_ descriptor: ChatSessionDescriptor) {
        guard Self.isSupported(descriptor) else {
            sessions.removeAll { $0.id == descriptor.id }
            return
        }
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

    private static func mergedMessages(
        serverMessages: [ChatMessage],
        localMessages: [ChatMessage]
    ) -> [ChatMessage] {
        var merged = localMessages
        for message in serverMessages {
            if let localIndex = merged.firstIndex(where: {
                isOptimisticMatch($0, serverMessage: message)
            }) {
                merged.remove(at: localIndex)
            }
            if let index = merged.firstIndex(where: { $0.id == message.id }) {
                merged[index] = message
            } else {
                merged.append(message)
            }
        }
        return merged.sorted { $0.seq < $1.seq }
    }

    private static func isOptimisticMatch(
        _ localMessage: ChatMessage,
        serverMessage: ChatMessage
    ) -> Bool {
        guard localMessage.id.hasPrefix("local-"),
              localMessage.role == serverMessage.role else { return false }
        guard case .prose(let localProse) = localMessage.kind,
              case .prose(let serverProse) = serverMessage.kind else { return false }
        return localProse.text == serverProse.text
    }

    private static func isSupported(_ session: ChatSessionDescriptor) -> Bool {
        MobileChatProvider.resolve(session.agentKind) != nil
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
