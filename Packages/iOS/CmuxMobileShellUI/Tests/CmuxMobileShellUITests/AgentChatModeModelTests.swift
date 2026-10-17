import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite struct AgentChatModeModelTests {
    @Test func sourceLoadSelectsNewestSessionAndLoadsHistory() async {
        let source = FakeAgentChatSource(sessions: [
            descriptor(id: "claude", agent: .claude, title: "Claude", activity: 10),
            descriptor(id: "codex", agent: .codex, title: "Codex", activity: 30),
            descriptor(id: "opencode", agent: .other("opencode"), title: "OpenCode", activity: 20),
        ], pages: [
            "claude": [page(message(id: "claude-1", seq: 1, text: "Claude history"))],
            "codex": [page(message(id: "codex-1", seq: 1, text: "Codex history"))],
            "opencode": [page(message(id: "opencode-1", seq: 1, text: "OpenCode history"))],
        ])
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()

        #expect(model.sessions.map(\.id) == ["codex", "opencode", "claude"])
        #expect(model.selectedSessionID == "codex")
        #expect(model.selectedMessages.map(\.id) == ["codex-1"])

        model.selectedProvider = "opencode"
        #expect(model.visibleSessions.map(\.id) == ["opencode"])
        model.selectedProvider = "all"
    }

    @Test func sessionSearchMatchesMetadataWithoutChangingProviderFilter() async {
        let source = FakeAgentChatSource(sessions: [
            ChatSessionDescriptor(
                id: "codex-build",
                agentKind: .codex,
                title: "Fix Café build",
                workspaceID: "workspace-a",
                workingDirectory: "/Users/me/Project",
                state: .idle,
                lastActivityAt: Date(timeIntervalSince1970: 10),
                version: 1
            ),
            descriptor(id: "claude-review", agent: .claude, title: "Review API", activity: 20),
        ], pages: [:])
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()

        model.sessionSearchQuery = "CAFE"
        #expect(model.visibleSessions.map(\.id) == ["codex-build"])
        model.selectedProvider = "claude"
        #expect(model.visibleSessions.isEmpty)
        model.sessionSearchQuery = "project"
        model.selectedProvider = "all"
        #expect(model.visibleSessions.map(\.id) == ["codex-build"])
    }

    @Test func hostStreamFinishingExposesReconnectingState() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()
        #expect(model.connectionState == .connected)

        await source.finishHostEvents()
        await settle()
        #expect(model.connectionState == .reconnecting)

        await model.refresh()
        await settle()
        let renamed = ChatSessionDescriptor(
            id: "session",
            agentKind: .codex,
            title: "Reconnected",
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 2
        )
        await source.emitHost(sessionID: "session", event: .descriptorChanged(renamed))
        await settle()

        #expect(model.connectionState == .connected)
        #expect(model.selectedSession?.title == "Reconnected")
    }

    @Test func hostStreamEOFResubscribesAndAppliesLaterFrames() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel(reconnectDelay: { _ in })

        model.updateSource(source)
        await settle()
        await source.finishHostEvents()
        await settle()

        #expect(await source.hostSubscriptionCount == 2)
        let renamed = ChatSessionDescriptor(
            id: "session",
            agentKind: .codex,
            title: "Reconnected",
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 2
        )
        await source.emitHost(sessionID: "session", event: .descriptorChanged(renamed))
        await settle()

        #expect(model.connectionState == .connected)
        #expect(model.selectedSession?.title == "Reconnected")
    }

    @Test func hostStreamEOFReloadsSelectedHistory() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [
                    page(message(id: "before-gap", seq: 1, text: "before gap")),
                    page(message(id: "during-gap", seq: 2, text: "during gap")),
                ],
            ]
        )
        let model = AgentChatModeModel(reconnectDelay: { _ in })

        model.updateSource(source)
        await settle()
        await source.finishHostEvents()
        await settle()

        #expect(model.selectedMessages.map(\.id) == ["during-gap"])
        #expect((await source.historyRequests).map(\.beforeSeq) == [nil, nil])
    }

    @Test func staleVersionedStatePushCannotOverwriteNewerDescriptor() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()

        let newer = ChatSessionDescriptor(
            id: "session",
            agentKind: .codex,
            title: "Newer",
            state: .working(since: Date(timeIntervalSince1970: 20)),
            lastActivityAt: Date(timeIntervalSince1970: 20),
            version: 3
        )
        await source.emitHost(sessionID: "session", event: .descriptorChanged(newer), version: 3)
        await source.emitHost(
            sessionID: "session",
            event: .stateChanged(.idle),
            version: 2
        )
        await settle()

        #expect(model.selectedSession?.title == "Newer")
        #expect(model.selectedSession?.state == newer.state)
        #expect(model.selectedSession?.version == 3)
    }

    @Test func staleVersionedTranscriptPushCannotOverwriteNewerMessage() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: ["session": [page(message(id: "one", seq: 1, text: "initial"))]]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()

        await source.emitHost(
            sessionID: "session",
            event: .updated([message(id: "one", seq: 1, text: "newer")]),
            version: 2
        )
        await source.emitHost(
            sessionID: "session",
            event: .updated([message(id: "one", seq: 1, text: "stale")]),
            version: 1
        )
        await settle()

        #expect(model.selectedMessages.map { proseText($0) } == ["newer"])
    }

    @Test func delayedPerSessionDuplicateCannotOverwriteHostUpdate() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: ["session": [page(message(id: "one", seq: 1, text: "initial"))]]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()
        await source.emitHost(
            sessionID: "session",
            event: .updated([message(id: "one", seq: 1, text: "newer")]),
            version: 2
        )
        await settle()

        // A second stream would strip the revision and could deliver this
        // older duplicate after the host-wide stream applied the newer one.
        await source.emit(
            sessionID: "session",
            event: .updated([message(id: "one", seq: 1, text: "stale")])
        )
        await settle()

        #expect(model.selectedMessages.map { proseText($0) } == ["newer"])
        #expect(await source.sessionSubscriptionCount == 0)
    }

    @Test func versionGapPullsSnapshotAndReloadsHistoryBeforeApplyingPush() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [
                    page(message(id: "before-gap", seq: 1, text: "before gap")),
                    page(message(id: "after-gap", seq: 2, text: "after gap")),
                ],
            ]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()
        #expect(model.selectedSession?.version == 1)
        #expect(await source.sessionRequests.isEmpty)

        let latest = ChatSessionDescriptor(
            id: "session",
            agentKind: .codex,
            title: "Latest",
            state: .working(since: Date(timeIntervalSince1970: 30)),
            lastActivityAt: Date(timeIntervalSince1970: 30),
            version: 4
        )
        await source.emitHost(
            sessionID: "session",
            event: .descriptorChanged(latest),
            version: 4
        )
        await settle()

        #expect(await source.sessionRequests == ["session"])
        #expect((await source.historyRequests).map(\.beforeSeq) == [nil, nil])
        #expect(model.selectedSession == latest)
        #expect(model.selectedMessages.map(\.id) == ["after-gap"])
    }

    @Test func historyPaginationDeduplicatesAndPrependsOlderMessages() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [
                    ChatHistoryPage(messages: [message(id: "new", seq: 2, text: "new")], hasMore: true),
                    ChatHistoryPage(messages: [
                        message(id: "old", seq: 1, text: "old"),
                        message(id: "new", seq: 2, text: "duplicate"),
                    ], hasMore: false),
                ],
            ]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()
        await model.loadOlderMessages()
        await settle()

        #expect(model.selectedMessages.map(\.id) == ["old", "new"])
        #expect(model.selectedMessages.last?.kind == .prose(ChatProse(text: "new")))
        #expect((await source.historyRequests).map(\.beforeSeq) == [nil, 2])
    }

    @Test func emptyOlderPageStopsPaginationWithoutRefetchingNewestPage() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [
                    ChatHistoryPage(messages: [message(id: "new", seq: 2, text: "new")], hasMore: true),
                    ChatHistoryPage(messages: [], hasMore: true),
                ],
            ]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()
        #expect(model.selectedHasMoreHistory)

        await model.loadOlderMessages()
        await settle()
        #expect(!model.selectedHasMoreHistory)
        #expect((await source.historyRequests).map(\.beforeSeq) == [nil, 2])

        await model.loadOlderMessages()
        await settle()
        #expect((await source.historyRequests).map(\.beforeSeq) == [nil, 2])
    }

    @Test func eventsUpsertStreamingStateAndResetTranscript() async {
        let initial = message(id: "one", seq: 1, text: "one")
        let replacement = message(id: "one", seq: 1, text: "edited")
        let appended = message(id: "two", seq: 2, text: "two")
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .claude)],
            pages: ["session": [page(initial)]]
        )
        let model = AgentChatModeModel()

        model.updateSource(source)
        await settle()
        await source.emitHost(sessionID: "session", event: .appended([appended]))
        await settle()
        #expect(model.selectedMessages.map(\.id) == ["one", "two"])

        await source.emitHost(sessionID: "session", event: .updated([replacement]))
        await settle()
        #expect(model.selectedMessages.map { proseText($0) } == ["edited", "two"])

        let streaming = message(id: "stream", seq: 3, text: "draft")
        await source.emitHost(sessionID: "session", event: .streamingProse(streaming))
        await settle()
        #expect(model.selectedStreamingMessage == streaming)

        let since = Date(timeIntervalSince1970: 42)
        await source.emitHost(sessionID: "session", event: .stateChanged(.needsInput(since: since)))
        await settle()
        #expect(model.selectedSession?.state == .needsInput(since: since))

        let renamed = ChatSessionDescriptor(
            id: "session",
            agentKind: .claude,
            title: "Renamed",
            state: .needsInput(since: since),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 2
        )
        await source.emitHost(sessionID: "session", event: .descriptorChanged(renamed))
        await settle()
        #expect(model.selectedSession?.title == "Renamed")

        await source.emitHost(sessionID: "session", event: .reset)
        await settle()
        #expect(model.selectedMessages.map(\.id) == ["one"])
        #expect(model.selectedStreamingMessage == nil)
        #expect((await source.historyRequests).map(\.beforeSeq) == [nil, nil])
    }

    @Test func transcriptResetSeedsRetryFromReplacementHistory() async {
        let source = FakeAgentChatSource(
            sessions: [
                ChatSessionDescriptor(
                    id: "session",
                    agentKind: .codex,
                    title: "Failed task",
                    state: .failed(since: Date(timeIntervalSince1970: 10), reason: "failed"),
                    lastActivityAt: Date(timeIntervalSince1970: 10),
                    version: 1
                ),
            ],
            pages: [
                "session": [
                    page(userMessage(id: "old", seq: 1, text: "old prompt")),
                    page(userMessage(id: "new", seq: 2, text: "replacement prompt")),
                ],
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        model.draft = "old prompt"
        await model.sendDraft()
        await source.emitHost(sessionID: "session", event: .reset)
        await settle()
        await model.retryLastTurn()

        #expect((await source.sent).map(\.0) == ["old prompt", "replacement prompt"])
    }

    @Test func sendAnswerAndInterruptForwardToTheSelectedSession() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: ["session": [page(message(id: "one", seq: 1, text: "one"))]]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        model.draft = "  Explain this diff  "
        await model.sendDraft()
        await model.answer(optionIndex: 2)
        await model.answer(optionIndex: 3, requestID: "question-1")
        await model.answer(optionIndex: 4, requestID: "question-1")
        await model.interrupt(hard: true)

        #expect((await source.sent).map(\.0) == ["Explain this diff"])
        #expect((await source.sent).map(\.1) == ["session"])
        #expect((await source.answers).map(\.0) == [2, 3])
        #expect((await source.answers).map(\.1) == ["session"])
        #expect((await source.interrupts).map(\.0) == [true])
        #expect((await source.interrupts).map(\.1) == ["session"])
        #expect(model.draft.isEmpty)
    }

    @Test func endedSessionIsReadOnlyAndDoesNotForwardMutations() async {
        let ended = ChatSessionDescriptor(
            id: "ended",
            agentKind: .codex,
            title: "Finished task",
            state: .ended,
            lastActivityAt: Date(timeIntervalSince1970: 20),
            version: 4
        )
        let source = FakeAgentChatSource(
            sessions: [ended],
            pages: ["ended": [page(message(id: "one", seq: 1, text: "done"))]]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        #expect(model.sessions.map(\.id) == ["ended"])
        #expect(model.selectedSession?.state == .ended)

        model.draft = "Do more work"
        await model.sendDraft()
        await model.answer(optionIndex: 0, requestID: "question")
        await model.interrupt()

        #expect(await source.sent.isEmpty)
        #expect(await source.answers.isEmpty)
        #expect(await source.interrupts.isEmpty)
        #expect(model.draft == "Do more work")
    }

    @Test func steerDraftInterruptsCurrentTurnThenSendsImmediately() async {
        let working = ChatSessionDescriptor(
            id: "working",
            agentKind: .codex,
            title: "Active task",
            state: .working(since: Date(timeIntervalSince1970: 10)),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 2
        )
        let source = FakeAgentChatSource(sessions: [working], pages: [:])
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        model.draft = "Use the smaller fixture"
        await model.steerDraft()

        #expect((await source.interrupts).map(\.0) == [false])
        #expect((await source.sent).map(\.0) == ["Use the smaller fixture"])
        #expect(model.draft.isEmpty)
    }

    @Test func retryKeepsTheFailedPromptWhenAnotherPromptIsQueuedBehindIt() async {
        let failed = ChatSessionDescriptor(
            id: "failed",
            agentKind: .codex,
            title: "Failed task",
            state: .failed(since: Date(timeIntervalSince1970: 10), reason: "send failed"),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 1
        )
        let source = FakeAgentChatSource(sessions: [failed], pages: [:])
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        await source.setFailSends(true)
        model.draft = "first prompt"
        await model.sendDraft()
        model.draft = "second prompt"
        await model.sendDraft()
        await source.setFailSends(false)
        await model.retryLastTurn()
        model.draft = "third prompt"
        await model.sendDraft()

        #expect((await source.sent).map(\.0) == ["first prompt", "second prompt", "third prompt"])
    }

    @Test func failedSteeredTurnRetriesTheSteeredInstruction() async {
        let working = ChatSessionDescriptor(
            id: "working",
            agentKind: .codex,
            title: "Active task",
            state: .working(since: Date(timeIntervalSince1970: 10)),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 2
        )
        let source = FakeAgentChatSource(
            sessions: [working],
            pages: ["working": [page(userMessage(id: "old", seq: 1, text: "superseded prompt"))]]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        model.draft = "Use the smaller fixture"
        await model.steerDraft()
        await source.emit(
            sessionID: "working",
            event: .stateChanged(.failed(
                since: Date(timeIntervalSince1970: 20),
                reason: "steered turn failed"
            ))
        )
        await settle()
        await model.retryLastTurn()

        #expect((await source.sent).map(\.0) == ["Use the smaller fixture", "Use the smaller fixture"])
    }

    @Test func sessionRemovalSelectsTheNextSession() async {
        let source = FakeAgentChatSource(
            sessions: [
                descriptor(id: "first", agent: .claude, activity: 20),
                descriptor(id: "second", agent: .codex, activity: 10),
            ],
            pages: [
                "first": [page(message(id: "first-message", seq: 1, text: "first"))],
                "second": [page(message(id: "second-message", seq: 1, text: "second"))],
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()
        #expect(model.selectedSessionID == "first")

        await source.emitHost(sessionID: "first", event: .sessionRemoved(version: 1))
        await settle()

        #expect(model.sessions.map(\.id) == ["second"])
        #expect(model.selectedSessionID == "second")

        await model.refresh()
        await settle()
        #expect(model.sessions.map(\.id) == ["second"])
    }

    private static func settle(_ turns: Int = 30) async {
        for _ in 0..<turns {
            await Task.yield()
        }
    }

    private func settle(_ turns: Int = 30) async {
        await Self.settle(turns)
    }

    private static func descriptor(
        id: String,
        agent: ChatAgentKind,
        title: String? = nil,
        activity: TimeInterval = 0
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: agent,
            title: title,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: activity),
            version: 1
        )
    }

    private static func page(_ message: ChatMessage) -> ChatHistoryPage {
        ChatHistoryPage(messages: [message], hasMore: false)
    }

    private static func message(id: String, seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func userMessage(id: String, seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .user,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func proseText(_ message: ChatMessage) -> String? {
        guard case .prose(let prose) = message.kind else { return nil }
        return prose.text
    }

    private func descriptor(
        id: String,
        agent: ChatAgentKind,
        title: String? = nil,
        activity: TimeInterval = 0
    ) -> ChatSessionDescriptor {
        Self.descriptor(id: id, agent: agent, title: title, activity: activity)
    }

    private func page(_ message: ChatMessage) -> ChatHistoryPage {
        Self.page(message)
    }

    private func message(id: String, seq: Int, text: String) -> ChatMessage {
        Self.message(id: id, seq: seq, text: text)
    }

    private func userMessage(id: String, seq: Int, text: String) -> ChatMessage {
        Self.userMessage(id: id, seq: seq, text: text)
    }

    private func proseText(_ message: ChatMessage) -> String? {
        Self.proseText(message)
    }
}

private actor FakeAgentChatSource: AgentChatSessionSource {
    struct HistoryRequest: Sendable, Equatable {
        let sessionID: String
        let beforeSeq: Int?
        let limit: Int
    }

    let sessionDescriptors: [ChatSessionDescriptor]
    let historyPages: [String: [ChatHistoryPage]]
    private var pageIndices: [String: Int] = [:]
    private(set) var historyRequests: [HistoryRequest] = []
    private(set) var sessionRequests: [String] = []
    private var failSends = false
    private(set) var sent: [(String, String)] = []
    private(set) var answers: [(Int, String)] = []
    private(set) var interrupts: [(Bool, String)] = []
    private var hostContinuation: AsyncStream<ChatSessionEventFrame>.Continuation?
    private(set) var hostSubscriptionCount = 0
    private var pendingHostEvents: [ChatSessionEventFrame] = []
    private(set) var sessionSubscriptionCount = 0
    private var eventContinuations: [String: AsyncStream<ChatSessionEvent>.Continuation] = [:]
    private var pendingEvents: [String: [ChatSessionEvent]] = [:]

    init(
        sessions: [ChatSessionDescriptor],
        pages: [String: [ChatHistoryPage]]
    ) {
        self.sessionDescriptors = sessions
        self.historyPages = pages
    }

    func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor] {
        sessionDescriptors
    }

    func session(sessionID: String) async throws -> ChatSessionDescriptor {
        sessionRequests.append(sessionID)
        guard let descriptor = sessionDescriptors.first(where: { $0.id == sessionID }) else {
            throw FakeError.missingSession
        }
        return descriptor
    }

    func sessionEvents() async -> AsyncStream<ChatSessionEventFrame> {
        hostSubscriptionCount += 1
        return AsyncStream { continuation in
            Task { await self.setHostContinuation(continuation) }
        }
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        historyRequests.append(HistoryRequest(sessionID: sessionID, beforeSeq: beforeSeq, limit: limit))
        let index = pageIndices[sessionID, default: 0]
        pageIndices[sessionID] = index + 1
        guard let pages = historyPages[sessionID], !pages.isEmpty else {
            return ChatHistoryPage(messages: [], hasMore: false)
        }
        return pages[min(index, pages.count - 1)]
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        sessionSubscriptionCount += 1
        return AsyncStream { continuation in
            Task { await self.setEventContinuation(continuation, for: sessionID) }
        }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        if failSends { throw FakeError.sendFailed }
        sent.append((text, sessionID))
    }

    func setFailSends(_ value: Bool) {
        failSends = value
    }

    func interrupt(sessionID: String, hard: Bool) async throws {
        interrupts.append((hard, sessionID))
    }

    func answer(optionIndex: Int, sessionID: String) async throws {
        answers.append((optionIndex, sessionID))
    }

    func emit(sessionID: String, event: ChatSessionEvent) {
        if let continuation = eventContinuations[sessionID] {
            continuation.yield(event)
        } else {
            pendingEvents[sessionID, default: []].append(event)
        }
    }

    func emitHost(sessionID: String, event: ChatSessionEvent, version: Int? = nil) {
        let frame = ChatSessionEventFrame(sessionID: sessionID, event: event, version: version)
        if let hostContinuation {
            hostContinuation.yield(frame)
        } else {
            pendingHostEvents.append(frame)
        }
    }

    private func setHostContinuation(_ continuation: AsyncStream<ChatSessionEventFrame>.Continuation) {
        hostContinuation = continuation
        pendingHostEvents.forEach { continuation.yield($0) }
        pendingHostEvents.removeAll()
    }

    func finishHostEvents() {
        hostContinuation?.finish()
        hostContinuation = nil
    }

    func finishEvents(sessionID: String) {
        eventContinuations[sessionID]?.finish()
        eventContinuations[sessionID] = nil
    }

    private func setEventContinuation(_ continuation: AsyncStream<ChatSessionEvent>.Continuation, for sessionID: String) {
        eventContinuations[sessionID] = continuation
        pendingEvents[sessionID, default: []].forEach { continuation.yield($0) }
        pendingEvents[sessionID] = nil
    }
}

private enum FakeError: Error {
    case missingSession
    case sendFailed
}
