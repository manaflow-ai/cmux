#if os(iOS)
import CmuxAgentChat
import CmuxMobileSupport
import Foundation
import Observation

/// Main-actor projection of every openable agent session into one Feed.
///
/// The store owns transport subscriptions and all mutations. Cards receive
/// closures into this store, so sending text, choosing an answer, interrupting
/// a turn, and refreshing a session have one behavior regardless of visual
/// variant.
@MainActor
@Observable
final class AgentFeedStore {
    private(set) var entries: [AgentFeedEntry] = []
    private(set) var sessions: [ChatSessionDescriptor] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var isFixture = false

    var attentionCount: Int {
        Set(entries.filter(\.requiresReply).map(\.sessionID)).count
    }

    private var source: (any ChatEventSource)?
    private var descriptorsByID: [String: ChatSessionDescriptor] = [:]
    private var messagesBySessionID: [String: [String: ChatMessage]] = [:]
    private var terminalBlocksBySessionID: [String: [Int: TerminalCommandBlock]] = [:]
    private var streamingBySessionID: [String: ChatMessage?] = [:]
    private var stateBySessionID: [String: ChatAgentState] = [:]
    private var workspaceNamesByID: [String: String] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var configurationKey = ""
    private var generation: UInt64 = 0

    init() {}

    static func fixture() -> AgentFeedStore {
        let store = AgentFeedStore()
        store.loadFixture()
        return store
    }

    /// Replaces the set of sessions observed by the Feed. A new source or
    /// session revision cancels old streams before starting fresh history and
    /// event subscriptions, which prevents stale Macs from writing into the
    /// current timeline after a connection switch.
    func configure(
        source: (any ChatEventSource)?,
        sessions: [ChatSessionDescriptor],
        workspaceNames: [String: String],
        sourceIdentity: String = ""
    ) {
        let orderedSessions = sessions.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
        let key = sourceIdentity + "|" + orderedSessions
            .map { "\($0.id):\($0.version):\($0.state)" }
            .joined(separator: ",")
        workspaceNamesByID = workspaceNames
        isFixture = false

        if key == configurationKey {
            self.sessions = orderedSessions
            rebuildEntries()
            return
        }

        configurationKey = key
        generation &+= 1
        cancelSubscriptions()
        self.source = source
        self.sessions = orderedSessions
        descriptorsByID = Dictionary(uniqueKeysWithValues: orderedSessions.map { ($0.id, $0) })
        messagesBySessionID = [:]
        terminalBlocksBySessionID = [:]
        streamingBySessionID = [:]
        stateBySessionID = Dictionary(uniqueKeysWithValues: orderedSessions.map { ($0.id, $0.state) })
        lastError = nil
        rebuildEntries()

        guard let source, !orderedSessions.isEmpty else {
            isLoading = false
            return
        }

        isLoading = true
        let currentGeneration = generation
        for descriptor in orderedSessions {
            startSubscription(
                source: source,
                descriptor: descriptor,
                generation: currentGeneration
            )
        }
    }

    /// Applies a live session-list snapshot without tearing down the history
    /// and event streams for sessions that are still present. The Mac emits a
    /// descriptor push for every state transition, so rebuilding every
    /// subscription on each push would turn a busy Feed into an RPC storm.
    func updateSessions(
        _ updatedSessions: [ChatSessionDescriptor],
        workspaceNames: [String: String]
    ) {
        guard source != nil else {
            sessions = updatedSessions.sorted {
                ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
            }
            workspaceNamesByID = workspaceNames
            descriptorsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            stateBySessionID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
            rebuildEntries()
            return
        }

        let ordered = updatedSessions.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
        let nextIDs = Set(ordered.map(\.id))
        let removedIDs = Set(descriptorsByID.keys).subtracting(nextIDs)
        for sessionID in removedIDs {
            eventTasks.removeValue(forKey: sessionID)?.cancel()
            descriptorsByID.removeValue(forKey: sessionID)
            messagesBySessionID.removeValue(forKey: sessionID)
            terminalBlocksBySessionID.removeValue(forKey: sessionID)
            streamingBySessionID.removeValue(forKey: sessionID)
            stateBySessionID.removeValue(forKey: sessionID)
        }

        let currentIDs = Set(descriptorsByID.keys)
        sessions = ordered
        descriptorsByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        for descriptor in ordered {
            stateBySessionID[descriptor.id] = descriptor.state
        }
        workspaceNamesByID = workspaceNames
        rebuildEntries()

        guard let source else { return }
        let currentGeneration = generation
        for descriptor in ordered where !currentIDs.contains(descriptor.id) {
            startSubscription(
                source: source,
                descriptor: descriptor,
                generation: currentGeneration
            )
        }
        isLoading = ordered.contains { eventTasks[$0.id] != nil && messagesBySessionID[$0.id] == nil }
    }

    func loadFixture() {
        generation &+= 1
        cancelSubscriptions()
        configurationKey = "fixture-v1"
        source = nil
        isFixture = true
        isLoading = false
        lastError = nil
        sessions = [AgentFeedFixture.descriptor]
        descriptorsByID = [AgentFeedFixture.sessionID: AgentFeedFixture.descriptor]
        workspaceNamesByID = [AgentFeedFixture.workspaceID: "cmux mobile"]
        messagesBySessionID = [
            AgentFeedFixture.sessionID: Dictionary(
                uniqueKeysWithValues: AgentFeedFixture.messages.map { ($0.id, $0) }
            ),
        ]
        terminalBlocksBySessionID = [
            AgentFeedFixture.sessionID: Dictionary(
                uniqueKeysWithValues: AgentFeedFixture.terminalBlocks.map { ($0.id, $0) }
            ),
        ]
        streamingBySessionID = [:]
        stateBySessionID = [AgentFeedFixture.sessionID: AgentFeedFixture.descriptor.state]
        rebuildEntries()
    }

    func descriptor(for sessionID: String) -> ChatSessionDescriptor? {
        descriptorsByID[sessionID]
    }

    func send(_ text: String, to sessionID: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let source else {
            guard isFixture else { return }
            appendFixtureMessage(
                ChatMessageKind.prose(ChatProse(text: text)),
                role: .user,
                sessionID: sessionID
            )
            stateBySessionID[sessionID] = .idle
            rebuildEntries()
            return
        }
        do {
            try await source.send(text: text, attachments: [], sessionID: sessionID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func answer(optionIndex: Int, in sessionID: String, messageID: String? = nil) async {
        guard let source else {
            guard isFixture else { return }
            answerFixture(optionIndex: optionIndex, sessionID: sessionID, messageID: messageID)
            return
        }
        do {
            try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func interrupt(sessionID: String, hard: Bool = false) async {
        guard let source else {
            guard isFixture else { return }
            appendFixtureMessage(
                .status(ChatStatusTransition(
                    event: .interrupted,
                    detail: hard ? "Hard stop" : "Stopped from Feed"
                )),
                role: .system,
                sessionID: sessionID
            )
            stateBySessionID[sessionID] = .idle
            rebuildEntries()
            return
        }
        do {
            try await source.interrupt(sessionID: sessionID, hard: hard)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func retry() async {
        guard let source else {
            if isFixture { loadFixture() }
            return
        }
        let currentSessions = sessions
        configure(
            source: source,
            sessions: currentSessions,
            workspaceNames: workspaceNamesByID,
            sourceIdentity: "retry-\(UUID().uuidString)"
        )
    }

    private func answerFixture(optionIndex: Int, sessionID: String, messageID: String?) {
        var values = messagesBySessionID[sessionID] ?? [:]
        guard let pending = values.values
            .sorted(by: { $0.seq < $1.seq })
            .first(where: { message in
                guard messageID == nil || message.id == messageID else { return false }
                return switch message.kind {
                case .permissionRequest(let request): request.resolution == nil
                case .question(let question): question.selectedOptionLabel == nil
                default: false
                }
            }) else { return }

        let updatedKind: ChatMessageKind?
        switch pending.kind {
        case .permissionRequest(let request):
            updatedKind = .permissionRequest(ChatPermissionRequest(
                title: request.title,
                subject: request.subject,
                resolution: optionIndex == 0 ? .approved : .denied
            ))
        case .question(let question):
            guard question.options.indices.contains(optionIndex) else { return }
            updatedKind = .question(ChatQuestion(
                prompt: question.prompt,
                options: question.options,
                selectedOptionLabel: question.options[optionIndex].label,
                questionID: question.questionID
            ))
        default:
            updatedKind = nil
        }
        guard let updatedKind else { return }
        values[pending.id] = ChatMessage(
            id: pending.id,
            seq: pending.seq,
            role: pending.role,
            timestamp: pending.timestamp,
            kind: updatedKind
        )
        messagesBySessionID[sessionID] = values
        stateBySessionID[sessionID] = .idle
        rebuildEntries()
    }

    private func appendFixtureMessage(
        _ kind: ChatMessageKind,
        role: ChatRole,
        sessionID: String
    ) {
        var values = messagesBySessionID[sessionID] ?? [:]
        let nextSeq = (values.values.map(\.seq).max() ?? 0) + 1
        let timestamp = Date()
        let message = ChatMessage(
            id: "fixture-local-\(nextSeq)",
            seq: nextSeq,
            role: role,
            timestamp: timestamp,
            kind: kind
        )
        values[message.id] = message
        messagesBySessionID[sessionID] = values
    }

    private func startSubscription(
        source: any ChatEventSource,
        descriptor: ChatSessionDescriptor,
        generation: UInt64
    ) {
        let sessionID = descriptor.id
        let task = Task { [weak self] in
            do {
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: nil,
                    limit: 200
                )
                guard !Task.isCancelled else { return }
                self?.apply(history: page, for: descriptor, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.record(error: error, generation: generation)
            }

            guard !Task.isCancelled else { return }
            let stream = await source.events(sessionID: sessionID)
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.apply(event: event, sessionID: sessionID, generation: generation)
            }
        }
        eventTasks[sessionID] = task
    }

    private func apply(
        history: ChatHistoryPage,
        for descriptor: ChatSessionDescriptor,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        messagesBySessionID[descriptor.id] = Dictionary(
            uniqueKeysWithValues: history.messages.map { ($0.id, $0) }
        )
        if let blocks = history.terminalBlocks {
            terminalBlocksBySessionID[descriptor.id] = Dictionary(
                uniqueKeysWithValues: blocks.map { ($0.id, $0) }
            )
        }
        isLoading = eventTasks.count < sessions.count
        rebuildEntries()
    }

    private func apply(
        event: ChatSessionEvent,
        sessionID: String,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        switch event {
        case .appended(let messages), .updated(let messages):
            var values = messagesBySessionID[sessionID] ?? [:]
            for message in messages { values[message.id] = message }
            messagesBySessionID[sessionID] = values
        case .stateChanged(let state):
            stateBySessionID[sessionID] = state
            if let descriptor = descriptorsByID[sessionID] {
                descriptorsByID[sessionID] = descriptor.withState(state)
                sessions = sessions.map { $0.id == sessionID ? descriptor.withState(state) : $0 }
            }
        case .descriptorChanged(let descriptor):
            descriptorsByID[sessionID] = descriptor
            stateBySessionID[sessionID] = descriptor.state
            sessions = sessions.map { $0.id == sessionID ? descriptor : $0 }
        case .sessionRemoved:
            stateBySessionID[sessionID] = .ended
        case .terminalBlocks(let blocks):
            var values = terminalBlocksBySessionID[sessionID] ?? [:]
            for block in blocks { values[block.id] = block }
            terminalBlocksBySessionID[sessionID] = values
        case .streamingProse(let message):
            streamingBySessionID[sessionID] = message
        case .reset:
            messagesBySessionID[sessionID] = [:]
            terminalBlocksBySessionID[sessionID] = [:]
            streamingBySessionID[sessionID] = nil
        case .unknown:
            break
        }
        isLoading = false
        rebuildEntries()
    }

    private func record(error: any Error, generation: UInt64) {
        guard generation == self.generation else { return }
        isLoading = false
        lastError = error.localizedDescription
        rebuildEntries()
    }

    private func rebuildEntries() {
        var rebuilt: [AgentFeedEntry] = []
        for descriptor in sessions {
            let sessionID = descriptor.id
            let state = stateBySessionID[sessionID] ?? descriptor.state
            let workspaceID = descriptor.workspaceID
            let workspaceName = workspaceID.flatMap { workspaceNamesByID[$0] }
                ?? descriptor.workingDirectory
                ?? L10n.string("mobile.feed.workspaceFallback", defaultValue: "Workspace")
            let agentName = descriptor.agentKind.displayName

            let messages = (messagesBySessionID[sessionID] ?? [:]).values.sorted {
                if $0.seq != $1.seq { return $0.seq < $1.seq }
                return $0.timestamp < $1.timestamp
            }
            for message in messages {
                rebuilt.append(AgentFeedEntry(
                    id: "message-\(sessionID)-\(message.id)",
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    terminalID: descriptor.terminalID,
                    agentName: agentName,
                    sessionTitle: descriptor.title,
                    timestamp: message.timestamp,
                    state: state,
                    content: .message(message),
                    requiresReply: requiresReply(for: message),
                    isStreaming: false
                ))
            }

            if let streaming = streamingBySessionID[sessionID] ?? nil {
                rebuilt.append(AgentFeedEntry(
                    id: "streaming-\(sessionID)",
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    terminalID: descriptor.terminalID,
                    agentName: agentName,
                    sessionTitle: descriptor.title,
                    timestamp: streaming.timestamp,
                    state: state,
                    content: .message(streaming),
                    requiresReply: false,
                    isStreaming: true
                ))
            }

            for block in (terminalBlocksBySessionID[sessionID] ?? [:]).values.sorted(by: { $0.id < $1.id }) {
                rebuilt.append(AgentFeedEntry(
                    id: "terminal-\(sessionID)-\(block.id)",
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    terminalID: descriptor.terminalID,
                    agentName: descriptor.kind == .terminal
                        ? L10n.string("mobile.feed.terminal.agentName", defaultValue: "Shell")
                        : agentName,
                    sessionTitle: descriptor.title,
                    timestamp: descriptor.lastActivityAt ?? .distantPast,
                    state: state,
                    content: .terminalBlock(block),
                    requiresReply: false,
                    isStreaming: block.isRunning
                ))
            }

            if case .needsInput(let since) = state {
                rebuilt.append(AgentFeedEntry(
                    id: "presence-\(sessionID)",
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    terminalID: descriptor.terminalID,
                    agentName: agentName,
                    sessionTitle: descriptor.title,
                    timestamp: since,
                    state: state,
                    content: .presence(state),
                    requiresReply: true,
                    isStreaming: false
                ))
            } else if case .idle = state,
                      let latestAgentMessage = messages.last(where: { $0.role == .agent }) {
                // An idle agent after an authored turn is a durable, inline
                // hand-off point. It makes the Feed explicit about who owns
                // the next move instead of relying on a disappearing spinner.
                rebuilt.append(AgentFeedEntry(
                    id: "presence-finished-\(sessionID)",
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    terminalID: descriptor.terminalID,
                    agentName: agentName,
                    sessionTitle: descriptor.title,
                    timestamp: latestAgentMessage.timestamp,
                    state: state,
                    content: .presence(state),
                    requiresReply: true,
                    isStreaming: false
                ))
            }
        }
        entries = Array(rebuilt.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id > $1.id
        }.prefix(240))
    }

    private func requiresReply(for message: ChatMessage) -> Bool {
        switch message.kind {
        case .permissionRequest(let request):
            return request.resolution == nil
        case .question(let question):
            return question.selectedOptionLabel == nil
        default:
            return false
        }
    }

    private func cancelSubscriptions() {
        for task in eventTasks.values { task.cancel() }
        eventTasks.removeAll()
    }

    isolated deinit {
        for task in eventTasks.values { task.cancel() }
    }
}
#endif
