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
    private(set) var hasMoreHistoryBySessionID: [String: Bool] = [:]
    private(set) var loadingOlderHistorySessionIDs: Set<String> = []

    private var source: MobileChatEventSource?
    private var sessionEventsTask: Task<Void, Never>?
    private var conversationTasks: [String: Task<Void, Never>] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var historyTasks: [String: Task<Void, Never>] = [:]
    private var openSessionIDs: Set<String> = []
    private var pendingLocalMessages: [String: [ChatMessage]] = [:]
    private var bufferedEventsBySessionID: [String: [ChatSessionEvent]] = [:]
    private var hydratingSessionIDs: Set<String> = []
    private var resettingSessionIDs: Set<String> = []
    private var resetTokensBySessionID: [String: UUID] = [:]
    private var sessionVersions: [String: Int] = [:]
    private var removedSessionVersions: [String: Int] = [:]
    private var refreshGeneration = UUID()

    isolated deinit {
        sessionEventsTask?.cancel()
        conversationTasks.values.forEach { $0.cancel() }
        eventTasks.values.forEach { $0.cancel() }
        historyTasks.values.forEach { $0.cancel() }
    }

    /// Loads the current Mac's chat roster and starts the roster event stream.
    func refresh(using store: CMUXMobileShellStore) async {
        let generation = UUID()
        clearPendingLocalMessages()
        refreshGeneration = generation
        let targetComputerID = store.connectedMacDeviceID
        if activeComputerID != targetComputerID {
            openSessionIDs.removeAll()
            messagesBySessionID.removeAll()
            streamingMessageBySessionID.removeAll()
            pendingLocalMessages.removeAll()
            hasMoreHistoryBySessionID.removeAll()
            loadingSessionIDs.removeAll()
            loadingOlderHistorySessionIDs.removeAll()
            bufferedEventsBySessionID.removeAll()
            hydratingSessionIDs.removeAll()
            resettingSessionIDs.removeAll()
            resetTokensBySessionID.removeAll()
            sessionVersions.removeAll()
            removedSessionVersions.removeAll()
            self.activeComputerID = targetComputerID
        }
        sessionEventsTask?.cancel()
        sessionEventsTask = nil
        conversationTasks.values.forEach { $0.cancel() }
        conversationTasks.removeAll()
        eventTasks.values.forEach { $0.cancel() }
        eventTasks.removeAll()
        historyTasks.values.forEach { $0.cancel() }
        historyTasks.removeAll()
        loadingOlderHistorySessionIDs.removeAll()
        bufferedEventsBySessionID.removeAll()
        hydratingSessionIDs.removeAll()
        resettingSessionIDs.removeAll()
        resetTokensBySessionID.removeAll()
        source = nil
        guard let nextSource = store.makeChatEventSource() else {
            guard refreshGeneration == generation else { return }
            openSessionIDs.removeAll()
            messagesBySessionID.removeAll()
            streamingMessageBySessionID.removeAll()
            pendingLocalMessages.removeAll()
            hasMoreHistoryBySessionID.removeAll()
            bufferedEventsBySessionID.removeAll()
            hydratingSessionIDs.removeAll()
            resettingSessionIDs.removeAll()
            resetTokensBySessionID.removeAll()
            loadingSessionIDs.removeAll()
            loadingOlderHistorySessionIDs.removeAll()
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
            let supported = loaded.filter(Self.isSupported)
            for descriptor in supported {
                if let removedVersion = removedSessionVersions[descriptor.id],
                   descriptor.version > removedVersion {
                    removedSessionVersions[descriptor.id] = nil
                }
            }
            sessions = Self.sortedSessions(
                supported.filter { descriptor in
                    guard let removedVersion = removedSessionVersions[descriptor.id] else { return true }
                    return descriptor.version > removedVersion
                }
            )
            sessionVersions = Dictionary(
                uniqueKeysWithValues: supported
                    .filter { descriptor in
                        guard let removedVersion = removedSessionVersions[descriptor.id] else { return true }
                        return descriptor.version > removedVersion
                    }
                    .map { ($0.id, $0.version) }
                    + removedSessionVersions.map { ($0.key, Int.max) }
            )
            hasMoreHistoryBySessionID = Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.id, false) }
            )
            openSessionIDs.formIntersection(Set(sessions.map(\.id)))
            loadingSessionIDs.formIntersection(openSessionIDs)
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

    private func open(
        sessionID: String,
        generation: UUID,
        resetToken: UUID? = nil
    ) {
        guard let source,
              removedSessionVersions[sessionID] == nil else { return }
        openSessionIDs.insert(sessionID)
        conversationTasks[sessionID]?.cancel()
        eventTasks[sessionID]?.cancel()
        eventTasks[sessionID] = nil
        historyTasks[sessionID]?.cancel()
        loadingSessionIDs.insert(sessionID)
        loadingOlderHistorySessionIDs.remove(sessionID)
        hasMoreHistoryBySessionID[sessionID] = false
        bufferedEventsBySessionID[sessionID] = []
        hydratingSessionIDs.insert(sessionID)
        conversationTasks[sessionID] = Task { [weak self] in
            do {
                // Register the live stream before taking the snapshot. The
                // source completes its server-side handshake before returning,
                // and the local stream buffers frames while history loads.
                let events = await source.events(sessionID: sessionID)
                guard !Task.isCancelled,
                      self?.refreshGeneration == generation,
                      self?.openSessionIDs.contains(sessionID) == true
                else { return }
                let eventTask = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled,
                              self?.refreshGeneration == generation,
                              self?.openSessionIDs.contains(sessionID) == true else { return }
                        self?.receive(event, for: sessionID, generation: generation)
                    }
                }
                self?.eventTasks[sessionID] = eventTask
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
                    self.messagesBySessionID[sessionID] = Self.mergedMessages(
                        serverMessages: page.messages,
                        localMessages: local
                    )
                    self.hasMoreHistoryBySessionID[sessionID] = page.hasMore && !page.messages.isEmpty
                    self.hydratingSessionIDs.remove(sessionID)
                    let buffered = self.bufferedEventsBySessionID.removeValue(forKey: sessionID) ?? []
                    for event in buffered {
                        self.apply(event, to: sessionID)
                    }
                    if let resetToken,
                       self.resetTokensBySessionID[sessionID] == resetToken {
                        self.resetTokensBySessionID[sessionID] = nil
                        self.resettingSessionIDs.remove(sessionID)
                    }
                }
                self?.loadingSessionIDs.remove(sessionID)
                await eventTask.value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                self?.hydratingSessionIDs.remove(sessionID)
                if let resetToken,
                   self?.resetTokensBySessionID[sessionID] == resetToken {
                    self?.resetTokensBySessionID[sessionID] = nil
                    self?.resettingSessionIDs.remove(sessionID)
                }
                self?.bufferedEventsBySessionID.removeValue(forKey: sessionID)
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
        eventTasks[sessionID]?.cancel()
        eventTasks[sessionID] = nil
        historyTasks[sessionID]?.cancel()
        historyTasks[sessionID] = nil
        bufferedEventsBySessionID[sessionID] = nil
        hydratingSessionIDs.remove(sessionID)
        resettingSessionIDs.remove(sessionID)
        resetTokensBySessionID[sessionID] = nil
        loadingOlderHistorySessionIDs.remove(sessionID)
        loadingSessionIDs.remove(sessionID)
        streamingMessageBySessionID[sessionID] = nil
    }

    /// Loads an older page for an open conversation. The live stream remains
    /// active while the page is fetched, so new messages cannot be displaced
    /// by the older snapshot.
    func loadOlderHistory(sessionID: String) {
        guard let source,
              openSessionIDs.contains(sessionID),
              hasMoreHistoryBySessionID[sessionID] == true,
              !loadingOlderHistorySessionIDs.contains(sessionID),
              let firstSeq = messagesBySessionID[sessionID]?.map(\.seq).min()
        else { return }

        let generation = refreshGeneration
        loadingOlderHistorySessionIDs.insert(sessionID)
        historyTasks[sessionID]?.cancel()
        historyTasks[sessionID] = Task { [weak self] in
            do {
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: firstSeq,
                    limit: 200
                )
                guard !Task.isCancelled,
                      let self,
                      self.refreshGeneration == generation,
                      self.openSessionIDs.contains(sessionID)
                else { return }
                let current = self.messagesBySessionID[sessionID, default: []]
                let local = self.pendingLocalMessages[sessionID, default: []]
                let merged = Self.mergedMessages(
                    serverMessages: page.messages,
                    localMessages: current + local
                )
                self.messagesBySessionID[sessionID] = merged
                let currentIDs = Set(current.map(\.id))
                let addedEarlierMessage = page.messages.contains {
                    $0.seq < firstSeq && !currentIDs.contains($0.id)
                }
                self.hasMoreHistoryBySessionID[sessionID] =
                    page.hasMore && !page.messages.isEmpty && addedEarlierMessage
                self.loadingOlderHistorySessionIDs.remove(sessionID)
                self.historyTasks[sessionID] = nil
                let buffered = self.bufferedEventsBySessionID.removeValue(forKey: sessionID) ?? []
                for event in buffered {
                    self.apply(event, to: sessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
                self.loadingOlderHistorySessionIDs.remove(sessionID)
                self.historyTasks[sessionID] = nil
                let buffered = self.bufferedEventsBySessionID.removeValue(forKey: sessionID) ?? []
                for event in buffered {
                    self.apply(event, to: sessionID)
                }
                self.errorMessage = "Earlier messages could not be loaded."
            }
        }
    }

    func hasMoreHistory(for sessionID: String) -> Bool {
        hasMoreHistoryBySessionID[sessionID] == true
    }

    func isLoadingOlderHistory(for sessionID: String) -> Bool {
        loadingOlderHistorySessionIDs.contains(sessionID)
    }

    /// Sends a prompt to an existing agent session.
    func send(_ text: String, to sessionID: String) async -> Bool {
        guard let currentSource = source else {
            errorMessage = "Connect a computer before sending a message."
            return false
        }
        let source = currentSource
        let generation = refreshGeneration
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.state != .ended
        else {
            errorMessage = "This chat has ended. Start a new chat to continue."
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let optimisticMessageID = "local-\(UUID().uuidString)"
        let optimisticStartedAt = Date()
        var transcript = messagesBySessionID[sessionID, default: []]
        let nextSeq = transcript.map(\.seq).max().map { $0 + 1 } ?? 0
        transcript.append(ChatMessage(
            id: optimisticMessageID,
            seq: nextSeq,
            role: .user,
            timestamp: optimisticStartedAt,
            kind: .prose(ChatProse(text: trimmed))
        ))
        messagesBySessionID[sessionID] = transcript
        pendingLocalMessages[sessionID, default: []].append(transcript.last!)
        updateSession(id: sessionID) { descriptor in
            descriptor.withState(
                .working(since: optimisticStartedAt),
                lastActivityAt: optimisticStartedAt
            )
        }
        do {
            try await source.send(text: trimmed, attachments: [], sessionID: sessionID)
            guard !Task.isCancelled,
                  refreshGeneration == generation,
                  self.source === source else {
                rollbackOptimisticSend(
                    sessionID: sessionID,
                    messageID: optimisticMessageID,
                    previousSession: session,
                    startedAt: optimisticStartedAt,
                    source: source,
                    generation: generation
                )
                return false
            }
            errorMessage = nil
            return true
        } catch is CancellationError {
            rollbackOptimisticSend(
                sessionID: sessionID,
                messageID: optimisticMessageID,
                previousSession: session,
                startedAt: optimisticStartedAt,
                source: source,
                generation: generation
            )
            return false
        } catch {
            guard refreshGeneration == generation, self.source === source else { return false }
            rollbackOptimisticSend(
                sessionID: sessionID,
                messageID: optimisticMessageID,
                previousSession: session,
                startedAt: optimisticStartedAt,
                source: source,
                generation: generation
            )
            errorMessage = "Your message could not be sent."
            return false
        }
    }

    /// Answers an in-transcript question or permission request.
    func answer(optionIndex: Int, in sessionID: String) async {
        guard let source else { return }
        let generation = refreshGeneration
        do {
            try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
        } catch {
            guard refreshGeneration == generation, self.source === source else { return }
            errorMessage = "That choice could not be sent."
        }
    }

    /// Interrupts a working agent turn.
    func interrupt(sessionID: String) async {
        guard let source else { return }
        let generation = refreshGeneration
        do {
            try await source.interrupt(sessionID: sessionID, hard: false)
        } catch {
            guard refreshGeneration == generation, self.source === source else { return }
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

    /// Produces a readable plain-text transcript for the conversation menu's
    /// copy action. Structured rows keep their useful identifying details
    /// instead of disappearing from the exported transcript.
    func copyText(for sessionID: String) -> String {
        messages(for: sessionID).compactMap { message in
            switch message.kind {
            case .prose(let prose):
                prose.text
            case .thought(let thought):
                "[Thought]\n\(thought.text)"
            case .toolUse(let tool):
                "[\(tool.toolName)] \(tool.summary)"
            case .terminal(let terminal):
                terminal.output.map { "$ \(terminal.command)\n\($0)" } ?? "$ \(terminal.command)"
            case .fileEdit(let edit):
                "[\(edit.operation)] \(edit.filePath)"
            case .permissionRequest(let request):
                "[Permission] \(request.title) \(request.subject)"
            case .question(let question):
                "[Question] \(question.prompt)"
            case .status(let status):
                "[Status] \(status.detail ?? status.event.rawValue)"
            case .attachment(let attachment):
                "[Attachment] \(attachment.displayName ?? "Attachment")"
            case .unsupported(let payload):
                "[Unsupported message: \(payload.rawType)]"
            }
        }
        .joined(separator: "\n\n")
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
        sessionVersions = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.version) }
        )
        hasMoreHistoryBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, false) }
        )
        loadingOlderHistorySessionIDs = []
        bufferedEventsBySessionID = [:]
        hydratingSessionIDs = []
        resettingSessionIDs = []
        resetTokensBySessionID = [:]
        removedSessionVersions = [:]
        errorMessage = nil
        isLoadingSessions = false
    }

    private func startSessionEvents(from source: MobileChatEventSource, generation: UUID) {
        sessionEventsTask = Task { [weak self] in
            let events = await source.sessionEvents()
            for await frame in events {
                guard !Task.isCancelled,
                      self?.refreshGeneration == generation else { return }
                self?.receive(
                    frame.event,
                    for: frame.sessionID,
                    generation: generation,
                    fromSessionList: true
                )
            }
        }
    }

    private func receive(
        _ event: ChatSessionEvent,
        for sessionID: String,
        generation: UUID,
        fromSessionList: Bool = false
    ) {
        guard refreshGeneration == generation else { return }
        if fromSessionList, openSessionIDs.contains(sessionID) {
            switch event {
            case .stateChanged, .descriptorChanged, .sessionRemoved:
                break
            default:
                return
            }
        }
        if case .sessionRemoved = event {
            apply(event, to: sessionID)
            return
        }
        if hydratingSessionIDs.contains(sessionID) || loadingOlderHistorySessionIDs.contains(sessionID) {
            bufferedEventsBySessionID[sessionID, default: []].append(event)
        } else {
            apply(event, to: sessionID)
        }
    }

    private func apply(_ event: ChatSessionEvent, to sessionID: String) {
        if removedSessionVersions[sessionID] != nil {
            guard case .descriptorChanged = event else { return }
            // A descriptor with a strictly newer revision can legitimately
            // reintroduce a session id after a removal tombstone.
        }
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
        case .sessionRemoved(let version):
            guard version > sessionVersions[sessionID, default: -1] else { return }
            sessionVersions[sessionID] = Int.max
            removedSessionVersions[sessionID] = version
            sessions.removeAll { $0.id == sessionID }
            removeSessionState(sessionID)
        case .reset:
            guard resettingSessionIDs.insert(sessionID).inserted else { return }
            messagesBySessionID[sessionID] = []
            streamingMessageBySessionID[sessionID] = nil
            pendingLocalMessages[sessionID] = []
            hasMoreHistoryBySessionID[sessionID] = false
            loadingOlderHistorySessionIDs.remove(sessionID)
            guard openSessionIDs.contains(sessionID) else {
                resettingSessionIDs.remove(sessionID)
                return
            }
            let resetToken = UUID()
            resetTokensBySessionID[sessionID] = resetToken
            bufferedEventsBySessionID[sessionID] = []
            hydratingSessionIDs.insert(sessionID)
            loadingSessionIDs.insert(sessionID)
            open(
                sessionID: sessionID,
                generation: refreshGeneration,
                resetToken: resetToken
            )
        case .terminalBlocks, .unknown:
            break
        }
    }

    private func upsertSession(_ descriptor: ChatSessionDescriptor) {
        if let removedVersion = removedSessionVersions[descriptor.id] {
            guard descriptor.version > removedVersion else { return }
            removedSessionVersions[descriptor.id] = nil
        } else {
            guard descriptor.version > sessionVersions[descriptor.id, default: -1] else { return }
        }
        sessionVersions[descriptor.id] = descriptor.version
        guard Self.isSupported(descriptor) else {
            sessions.removeAll { $0.id == descriptor.id }
            return
        }
        if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
            sessions[index] = descriptor
        } else {
            sessions.append(descriptor)
        }
        if hasMoreHistoryBySessionID[descriptor.id] == nil {
            hasMoreHistoryBySessionID[descriptor.id] = false
        }
        sessions = Self.sortedSessions(sessions)
    }

    private func updateSession(
        id: String,
        transform: (ChatSessionDescriptor) -> ChatSessionDescriptor
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index] = transform(sessions[index])
        sessions = Self.sortedSessions(sessions)
    }

    private func removeSessionState(_ sessionID: String) {
        openSessionIDs.remove(sessionID)
        conversationTasks[sessionID]?.cancel()
        conversationTasks[sessionID] = nil
        eventTasks[sessionID]?.cancel()
        eventTasks[sessionID] = nil
        historyTasks[sessionID]?.cancel()
        historyTasks[sessionID] = nil
        loadingSessionIDs.remove(sessionID)
        loadingOlderHistorySessionIDs.remove(sessionID)
        bufferedEventsBySessionID[sessionID] = nil
        hydratingSessionIDs.remove(sessionID)
        resettingSessionIDs.remove(sessionID)
        resetTokensBySessionID[sessionID] = nil
        messagesBySessionID[sessionID] = nil
        streamingMessageBySessionID[sessionID] = nil
        pendingLocalMessages[sessionID] = nil
        hasMoreHistoryBySessionID[sessionID] = nil
    }

    private func clearPendingLocalMessages() {
        for (sessionID, pending) in pendingLocalMessages {
            let pendingIDs = Set(pending.map(\.id))
            messagesBySessionID[sessionID]?.removeAll { pendingIDs.contains($0.id) }
        }
        pendingLocalMessages.removeAll()
    }

    private func rollbackOptimisticSend(
        sessionID: String,
        messageID: String,
        previousSession: ChatSessionDescriptor,
        startedAt: Date,
        source: MobileChatEventSource,
        generation: UUID
    ) {
        guard refreshGeneration == generation, self.source === source else { return }
        // A failed request must not leave a prompt that never reached the Mac
        // in the transcript. If a server echo already reconciled it, the
        // optimistic row has been replaced and this removal is a no-op.
        messagesBySessionID[sessionID]?.removeAll { $0.id == messageID }
        pendingLocalMessages[sessionID]?.removeAll { $0.id == messageID }
        updateSession(id: sessionID) { descriptor in
            guard descriptor.lastActivityAt == startedAt else { return descriptor }
            return descriptor.withState(
                previousSession.state,
                lastActivityAt: previousSession.lastActivityAt
            )
        }
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
        var merged: [ChatMessage] = []
        for message in localMessages {
            if let index = merged.firstIndex(where: { $0.id == message.id }) {
                merged[index] = message
            } else {
                merged.append(message)
            }
        }
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
        guard serverMessage.seq >= localMessage.seq else { return false }
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
