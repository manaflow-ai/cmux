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

    @Test func forkLaunchDeduplicatesAndSelectsChildTerminal() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "parent", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        let launchGate = await source.holdLaunches()
        let child = descriptor(
            id: "child",
            agent: .codex,
            title: "Side chat",
            activity: 20
        )
        await source.setLaunchResult(
            ChatSessionLaunchResult(
                action: .fork,
                parentSessionID: "parent",
                sessionID: "child",
                workspaceID: "workspace",
                terminalID: "child-terminal"
            ),
            adding: child
        )
        let launchTask = Task { await model.forkSelectedSession() }
        await source.waitForLaunchStart()
        #expect(model.isLaunchingSelectedSession)

        // A second tap while the host request is crossing the boundary is a
        // no-op, so only one provider terminal is created.
        await model.forkSelectedSession()
        #expect((await source.launches).count == 1)

        await launchGate.open()
        await launchTask.value
        #expect(model.selectedSessionID == "child")
        #expect(!model.isLaunchingSelectedSession)
    }

    @Test func staleLaunchCannotSelectAReplacementSourceSession() async {
        let oldSource = FakeAgentChatSource(
            sessions: [descriptor(id: "parent", agent: .codex, title: "Old parent")],
            pages: [:]
        )
        let model = AgentChatModeModel()
        model.updateSource(oldSource)
        await settle()

        let launchGate = await oldSource.holdLaunches()
        await oldSource.setLaunchResult(
            ChatSessionLaunchResult(
                action: .fork,
                parentSessionID: "parent",
                sessionID: "shared-child",
                workspaceID: "old-workspace",
                terminalID: "old-terminal"
            ),
            adding: descriptor(id: "shared-child", agent: .codex, title: "Old side chat")
        )
        let launchTask = Task { await model.forkSelectedSession() }
        await oldSource.waitForLaunchStart()

        let replacementSource = FakeAgentChatSource(sessions: [
            descriptor(id: "replacement", agent: .claude, title: "Replacement", activity: 20),
            // The replacement Mac happens to use the same session ID. A stale
            // launch acknowledgement must not select this unrelated session.
            descriptor(id: "shared-child", agent: .claude, title: "Unrelated", activity: 10),
        ], pages: [:])
        model.updateSource(replacementSource)
        await settle()
        #expect(model.selectedSessionID == "replacement")

        await launchGate.open()
        await launchTask.value
        await settle()

        #expect(model.sessions.map(\.id) == ["replacement", "shared-child"])
        #expect(model.selectedSessionID == "replacement")
    }

    @Test func staleLaunchCompletionCannotClearReplacementLaunchInFlightState() async {
        let oldSource = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex, title: "Old")],
            pages: [:]
        )
        let model = AgentChatModeModel()
        model.updateSource(oldSource)
        await settle()

        let oldLaunchGate = await oldSource.holdLaunches()
        let oldLaunch = Task { await model.forkSelectedSession() }
        await oldSource.waitForLaunchStart()

        let replacementSource = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .claude, title: "Replacement")],
            pages: [:]
        )
        model.updateSource(replacementSource)
        await settle()
        let replacementLaunchGate = await replacementSource.holdLaunches()
        let replacementLaunch = Task { await model.forkSelectedSession() }
        await replacementSource.waitForLaunchStart()
        #expect(model.isLaunchingSelectedSession)

        await oldLaunchGate.open()
        await oldLaunch.value
        await settle()
        #expect(model.isLaunchingSelectedSession)

        await replacementLaunchGate.open()
        await replacementLaunch.value
    }

    @Test func staleControlsFetchCannotMutateAReplacementSource() async {
        let old = descriptor(
            id: "session",
            agent: .codex,
            title: "Old",
            controls: ChatSessionControls(modelID: "old-model")
        )
        let oldSource = FakeAgentChatSource(sessions: [old], pages: [:])
        let controlsGate = await oldSource.holdControls()
        let model = AgentChatModeModel()
        model.updateSource(oldSource)
        await oldSource.waitForControlsStart()

        let replacement = descriptor(
            id: "session",
            agent: .claude,
            title: "Replacement",
            controls: ChatSessionControls(modelID: "replacement-model")
        )
        let replacementSource = FakeAgentChatSource(sessions: [replacement], pages: [:])
        model.updateSource(replacementSource)
        await settle()

        await controlsGate.open()
        await settle()

        #expect(model.sessions.map(\.id) == ["session"])
        #expect(model.selectedSessionID == "session")
        #expect(model.selectedSession?.title == "Replacement")
        #expect(model.selectedControls.modelID == "replacement-model")
    }

    @Test func staleControlsReadCannotOverwriteAnAcknowledgedUpdate() async {
        let session = descriptor(
            id: "session",
            agent: .codex,
            controls: ChatSessionControls(modelID: "old-model")
        )
        let source = FakeAgentChatSource(sessions: [session], pages: [:])
        let controlsGate = await source.holdControls()
        let model = AgentChatModeModel()
        model.updateSource(source)
        await source.waitForControlsStart()

        let updated = ChatSessionControls(modelID: "new-model")
        await model.updateSelectedControls(updated)
        await controlsGate.open()
        await settle()

        #expect(model.selectedControls == updated)
        #expect(model.selectedSession?.controls == updated)
    }

    @Test func providerFilterReconcilesSelectedDetailSession() async {
        let source = FakeAgentChatSource(sessions: [
            descriptor(id: "claude", agent: .claude, title: "Claude", activity: 10),
            descriptor(id: "codex", agent: .codex, title: "Codex", activity: 30),
        ], pages: [:])
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        #expect(model.selectedSessionID == "codex")
        model.selectedProvider = "claude"
        model.reconcileSelectionToFilter()
        #expect(model.selectedSessionID == "claude")

        model.selectedProvider = "opencode"
        model.reconcileSelectionToFilter()
        #expect(model.selectedSessionID == nil)
    }

    @Test func idleSessionDoesNotConsumeDraftAsStaleQuestionAnswer() async {
        let question = questionMessage(
            id: "question",
            seq: 1,
            question: ChatQuestion(
                prompt: "Which target?",
                options: [ChatQuestion.Option(label: "iPhone")]
            )
        )
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: ["session": [page(question)]])
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        model.draft = "Continue with the implementation"
        await model.sendDraft()

        #expect((await source.sent).map(\.0) == ["Continue with the implementation"])
        #expect(await source.answers.isEmpty)
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

    @Test func sessionSearchMatchesLoadedTranscriptContent() async {
        let source = FakeAgentChatSource(
            sessions: [
                descriptor(id: "session", agent: .codex, title: "Build task", activity: 10),
                descriptor(id: "other", agent: .claude, title: "Unrelated", activity: 20),
            ],
            pages: [
                "session": [page(message(id: "one", seq: 1, text: "Searchable deployment token"))],
                "other": [page(message(id: "two", seq: 1, text: "Different content"))],
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        model.sessionSearchQuery = "deployment token"
        await model.searchTranscripts()
        #expect(model.visibleSessions.map(\.id) == ["session"])
    }

    @Test func transcriptSearchHydratesUnopenedSessions() async {
        let source = FakeAgentChatSource(
            sessions: [
                descriptor(id: "older", agent: .codex, title: "Older task", activity: 10),
                descriptor(id: "newer", agent: .claude, title: "Newer task", activity: 20),
            ],
            pages: [
                "older": [page(message(id: "older-message", seq: 1, text: "Find this remote transcript"))],
                "newer": [page(message(id: "newer-message", seq: 1, text: "Different content"))],
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        // The newest session is selected and hydrated automatically; the
        // older session must be fetched by the explicit transcript search.
        #expect(model.messagesBySession["older"] == nil)
        model.sessionSearchQuery = "remote transcript"
        await model.searchTranscripts()

        #expect(model.visibleSessions.map(\.id) == ["older"])
        #expect((await source.historyRequests).contains { $0.sessionID == "older" })
    }

    @Test func selectedPendingActionableCountOnlyIncludesUnresolvedCards() async {
        let session = ChatSessionDescriptor(
            id: "needs-input",
            agentKind: .codex,
            title: "Review the change",
            state: .needsInput(since: Date(timeIntervalSince1970: 10)),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            version: 1
        )
        let permission = ChatMessage(
            id: "permission",
            seq: 1,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .permissionRequest(ChatPermissionRequest(
                title: "Allow command",
                subject: "swift test"
            ))
        )
        let answeredPermission = ChatMessage(
            id: "answered-permission",
            seq: 2,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 2),
            kind: .permissionRequest(ChatPermissionRequest(
                title: "Allow command",
                subject: "git status",
                resolution: .approved
            ))
        )
        let question = ChatMessage(
            id: "question",
            seq: 3,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 3),
            kind: .question(ChatQuestion(
                prompt: "Which target?",
                options: [.init(label: "iOS")]
            ))
        )
        let answeredQuestion = ChatMessage(
            id: "answered-question",
            seq: 4,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 4),
            kind: .question(ChatQuestion(
                prompt: "Which target?",
                options: [.init(label: "iOS")],
                selectedOptionLabel: "iOS"
            ))
        )
        let source = FakeAgentChatSource(
            sessions: [session],
            pages: ["needs-input": [ChatHistoryPage(
                messages: [permission, answeredPermission, question, answeredQuestion],
                hasMore: false
            )]]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        #expect(model.selectedPendingActionableCount == 2)
    }

    @Test func pinAndArchivePreferencesPersistAcrossModels() {
        let suiteName = "AgentChatModeModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AgentChatModeModel(defaults: defaults)
        first.togglePinned("pinned")
        first.toggleArchived("archived")

        let second = AgentChatModeModel(defaults: defaults)
        #expect(second.pinnedSessionIDs == Set(["pinned"]))
        #expect(second.archivedSessionIDs == Set(["archived"]))
    }

    @Test func editPromptLoadsLatestUserProseIntoComposer() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: ["session": [page(userMessage(id: "prompt", seq: 1, text: "Inspect this diff"))]]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        guard let message = model.selectedMessages.first else {
            Issue.record("Expected the user prompt to load")
            return
        }
        model.editPrompt(message)

        #expect(model.draft == "Inspect this diff")
        #expect(model.attachments.isEmpty)
    }

    @Test func regenerateLatestResponseReplaysTheLatestUserPrompt() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [ChatHistoryPage(
                    messages: [
                        userMessage(id: "prompt", seq: 1, text: "  Inspect this diff  "),
                        message(id: "response", seq: 2, text: "The diff is safe to merge.")
                    ],
                    hasMore: false
                )]
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        #expect(model.latestAgentResponseID == "response")
        #expect(model.canRegenerateLatestResponse)

        await model.regenerateLatestResponse()

        #expect((await source.sent).map(\.0) == ["Inspect this diff"])
        #expect((await source.sent).map(\.1) == ["session"])
        #expect(model.regeneratingSessionIDs.isEmpty)
    }

    @Test func regenerateIsUnavailableWhenTheLatestTranscriptItemIsNotAnAgentResponse() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [ChatHistoryPage(
                    messages: [
                        userMessage(id: "prompt", seq: 1, text: "Inspect this diff"),
                        message(id: "response", seq: 2, text: "The diff is safe to merge."),
                        userMessage(id: "follow-up", seq: 3, text: "Check the tests too")
                    ],
                    hasMore: false
                )]
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        #expect(model.latestAgentResponseID == nil)
        #expect(!model.canRegenerateLatestResponse)

        await model.regenerateLatestResponse()
        #expect((await source.sent).isEmpty)
    }

    @Test func regenerateIgnoresDuplicateTapsWhileTheSendIsInFlight() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .claude)],
            pages: [
                "session": [ChatHistoryPage(
                    messages: [
                        userMessage(id: "prompt", seq: 1, text: "Explain the failure"),
                        message(id: "response", seq: 2, text: "The process exited with code 1.")
                    ],
                    hasMore: false
                )]
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        let sendGate = await source.holdSends()
        let first = Task { await model.regenerateLatestResponse() }
        await source.waitForSendStart()
        #expect(model.regeneratingSessionIDs == Set(["session"]))

        await model.regenerateLatestResponse()
        #expect((await source.sent).map(\.0) == ["Explain the failure"])

        await sendGate.open()
        await first.value
        // The send RPC can return before the host publishes the new turn.
        // Keep the action disabled until that authoritative state arrives.
        #expect(model.regeneratingSessionIDs == Set(["session"]))
        await source.emitHost(
            sessionID: "session",
            event: .stateChanged(.working(since: Date(timeIntervalSince1970: 20)))
        )
        await settle()
        #expect(model.regeneratingSessionIDs.isEmpty)
    }

    @Test func hostStreamFinishingExposesReconnectingState() async {
        let reconnectGate = TestAsyncGate()
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel(reconnectDelay: { _ in
            await reconnectGate.wait()
        })

        model.updateSource(source)
        await settle()
        #expect(model.connectionState == .connected)

        await source.finishHostEvents()
        await settle()
        #expect(model.connectionState == .reconnecting)

        await reconnectGate.open()
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
        #expect((await source.answers).map(\.1) == ["session", "session"])
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

    @Test func actionableCardsExposePendingCountUntilHostResolvesThem() async {
        let permission = permissionMessage(
            id: "permission",
            seq: 1,
            request: ChatPermissionRequest(
                title: "Codex wants to run",
                subject: "swift test",
                scope: "project"
            )
        )
        let question = questionMessage(
            id: "question",
            seq: 2,
            question: ChatQuestion(
                prompt: "Which target should I use?",
                options: [
                    ChatQuestion.Option(label: "iPhone"),
                    ChatQuestion.Option(label: "iPad")
                ],
                questionID: "target"
            )
        )
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: ["session": [ChatHistoryPage(messages: [permission, question], hasMore: false)]]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        #expect(model.selectedPendingActionableCount == 2)

        await source.emitHost(
            sessionID: "session",
            event: .updated([
                permissionMessage(
                    id: "permission",
                    seq: 1,
                    request: ChatPermissionRequest(
                        title: "Codex wants to run",
                        subject: "swift test",
                        resolution: .approved,
                        scope: "project"
                    )
                )
            ])
        )
        await settle()
        #expect(model.selectedPendingActionableCount == 1)

        await source.emitHost(
            sessionID: "session",
            event: .updated([
                questionMessage(
                    id: "question",
                    seq: 2,
                    question: ChatQuestion(
                        prompt: "Which target should I use?",
                        options: [
                            ChatQuestion.Option(label: "iPhone"),
                            ChatQuestion.Option(label: "iPad")
                        ],
                        selectedOptionLabel: "iPad",
                        questionID: "target"
                    )
                )
            ])
        )
        await settle()
        #expect(model.selectedPendingActionableCount == 0)
    }

    @Test func answerCardsDisableDuplicateSubmissionUntilResolutionArrives() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [
                "session": [page(questionMessage(
                    id: "permission",
                    seq: 1,
                    question: ChatQuestion(
                        prompt: "Allow this command?",
                        options: [ChatQuestion.Option(label: "Allow once"), ChatQuestion.Option(label: "Deny")],
                        questionID: "permission-1"
                    )
                ))]
            ]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        let answerGate = await source.holdAnswers()
        let answerTask = Task { await model.answer(optionIndex: 0, requestID: "permission-1") }
        await source.waitForAnswerStart()
        #expect(model.isAnswering(requestID: "permission-1"))

        // A second tap while the RPC is in flight must not submit another
        // answer or change the request identity used by the first tap.
        await model.answer(optionIndex: 1, requestID: "permission-1")
        #expect((await source.answers).map(\.0) == [0])
        #expect((await source.answers).map(\.1) == ["session"])

        await answerGate.open()
        await answerTask.value
        #expect(!model.isAnswering(requestID: "permission-1"))

        await source.emitHost(
            sessionID: "session",
            event: .updated([
                questionMessage(
                    id: "permission",
                    seq: 1,
                    question: ChatQuestion(
                        prompt: "Allow this command?",
                        options: [ChatQuestion.Option(label: "Allow once"), ChatQuestion.Option(label: "Deny")],
                        selectedOptionLabel: "Allow once",
                        questionID: "permission-1"
                    )
                )
            ])
        )
        await settle()
        await model.answer(optionIndex: 0, requestID: "permission-1")
        #expect((await source.answers).map(\.0) == [0])
    }

    @Test func pendingPromptsStayVisibleWhileQueuedAndDrainInOrder() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        let sendGate = await source.holdSends()
        model.draft = "first instruction"
        let firstSend = Task { await model.sendDraft() }
        await source.waitForSendStart()
        #expect(model.selectedPendingPrompts == ["first instruction"])

        model.draft = "second instruction"
        await model.sendDraft()
        #expect(model.queuedSendCount == 1)
        #expect(model.selectedPendingPrompts == ["first instruction", "second instruction"])

        await sendGate.open()
        await firstSend.value
        await source.emitHost(
            sessionID: "session",
            event: .appended([
                userMessage(id: "first", seq: 1, text: "first instruction"),
                userMessage(id: "second", seq: 2, text: "second instruction"),
            ])
        )
        await settle()
        #expect(model.selectedPendingPrompts.isEmpty)
        #expect((await source.sent).map(\.0) == ["first instruction", "second instruction"])
    }

    @Test func attachmentsAreDeduplicatedAndForwardedWithThePrompt() async {
        let source = FakeAgentChatSource(
            sessions: [descriptor(id: "session", agent: .codex)],
            pages: [:]
        )
        let model = AgentChatModeModel()
        model.updateSource(source)
        await settle()

        let payload = Data([0x89, 0x50, 0x4e, 0x47])
        let first = AgentChatModeModel.PendingAttachment(
            displayName: "screen.png",
            data: payload,
            format: .png,
            thumbnailData: payload
        )
        let duplicate = AgentChatModeModel.PendingAttachment(
            displayName: "copy.png",
            data: payload,
            format: .png
        )
        model.addAttachment(first)
        model.addAttachment(duplicate)
        #expect(model.attachments == [first])

        let sendGate = await source.holdSends()
        model.draft = "Review this screenshot"
        let sendTask = Task { await model.sendDraft() }
        await source.waitForSendStart()
        #expect(model.attachments.isEmpty)
        #expect(await source.sentAttachments == [[ChatOutboundAttachment(data: payload, format: .png)]])

        await sendGate.open()
        await sendTask.value
        await source.emitHost(
            sessionID: "session",
            event: .appended([userMessage(id: "prompt", seq: 1, text: "Review this screenshot")])
        )
        await settle()
        #expect(model.selectedPendingPrompts.isEmpty)
    }

    @Test func attachmentStagingTracksProgressAndCancellationPerFile() {
        let firstID = UUID()
        let secondID = UUID()
        let model = AgentChatModeModel()
        model.beginAttachmentStaging([
            .init(id: firstID, displayName: "screen.png", format: .png),
            .init(id: secondID, displayName: "notes.md", format: .file),
        ])

        #expect(model.attachmentStaging.map(\.displayName) == ["screen.png", "notes.md"])
        model.updateAttachmentStaging(
            id: firstID,
            state: .preparing,
            progress: 0.45
        )
        #expect(model.attachmentStaging.first(where: { $0.id == firstID })?.progress == 0.45)
        #expect(model.attachmentStaging.first(where: { $0.id == firstID })?.state == .preparing)

        model.finishAttachmentStagingItem(id: firstID)
        #expect(model.attachmentStaging.first(where: { $0.id == firstID })?.isTerminal == true)
        #expect(model.attachmentStaging.first(where: { $0.id == firstID })?.progress == 1)

        model.cancelAttachmentStaging()
        #expect(model.attachmentStaging.first(where: { $0.id == firstID })?.state == .completed)
        #expect(model.attachmentStaging.first(where: { $0.id == secondID })?.state == .cancelled)

        model.endAttachmentStaging()
        #expect(model.attachmentStaging.isEmpty)
    }

    @Test func staleAttachmentStagingBatchCannotClearNewerBatch() {
        let model = AgentChatModeModel()
        let firstGeneration = model.beginAttachmentStaging([
            .init(displayName: "old.txt", format: .file)
        ])
        let secondGeneration = model.beginAttachmentStaging([
            .init(displayName: "new.txt", format: .file)
        ])

        model.endAttachmentStaging(generation: firstGeneration)
        #expect(model.attachmentStaging.map(\.displayName) == ["new.txt"])
        model.endAttachmentStaging(generation: secondGeneration)
        #expect(model.attachmentStaging.isEmpty)
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
        await source.emitHost(
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
        activity: TimeInterval = 0,
        controls: ChatSessionControls = ChatSessionControls()
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: agent,
            title: title,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: activity),
            version: 1,
            controls: controls
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

    private static func permissionMessage(
        id: String,
        seq: Int,
        request: ChatPermissionRequest
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .permissionRequest(request)
        )
    }

    private static func questionMessage(
        id: String,
        seq: Int,
        question: ChatQuestion
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .question(question)
        )
    }

    private func descriptor(
        id: String,
        agent: ChatAgentKind,
        title: String? = nil,
        activity: TimeInterval = 0,
        controls: ChatSessionControls = ChatSessionControls()
    ) -> ChatSessionDescriptor {
        Self.descriptor(id: id, agent: agent, title: title, activity: activity, controls: controls)
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

    private func permissionMessage(
        id: String,
        seq: Int,
        request: ChatPermissionRequest
    ) -> ChatMessage {
        Self.permissionMessage(id: id, seq: seq, request: request)
    }

    private func questionMessage(
        id: String,
        seq: Int,
        question: ChatQuestion
    ) -> ChatMessage {
        Self.questionMessage(id: id, seq: seq, question: question)
    }
}

private actor FakeAgentChatSource: AgentChatSessionSource {
    struct HistoryRequest: Sendable, Equatable {
        let sessionID: String
        let beforeSeq: Int?
        let limit: Int
    }

    private var sessionDescriptors: [ChatSessionDescriptor]
    let historyPages: [String: [ChatHistoryPage]]
    private var pageIndices: [String: Int] = [:]
    private(set) var historyRequests: [HistoryRequest] = []
    private(set) var sessionRequests: [String] = []
    private var failSends = false
    private(set) var sent: [(String, String)] = []
    private(set) var sentAttachments: [[ChatOutboundAttachment]] = []
    private(set) var answers: [(Int, String)] = []
    private(set) var interrupts: [(Bool, String)] = []
    private(set) var launches: [(ChatSessionLaunchResult.Action, String)] = []
    private var launchResult: ChatSessionLaunchResult?
    private var launchReleaseGate: TestAsyncGate?
    private var launchStarted = 0
    private var launchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendReleaseGate: TestAsyncGate?
    private var sendStarted = 0
    private var sendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var answerReleaseGate: TestAsyncGate?
    private var answerStarted = 0
    private var answerStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var controlsReleaseGate: TestAsyncGate?
    private var controlsStarted = 0
    private var controlsStartWaiters: [CheckedContinuation<Void, Never>] = []
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

    func fork(sessionID: String) async throws -> ChatSessionLaunchResult {
        try await launch(.fork, sessionID: sessionID)
    }

    func resume(sessionID: String) async throws -> ChatSessionLaunchResult {
        try await launch(.resume, sessionID: sessionID)
    }

    func reopen(sessionID: String) async throws -> ChatSessionLaunchResult {
        try await launch(.reopen, sessionID: sessionID)
    }

    private func launch(
        _ action: ChatSessionLaunchResult.Action,
        sessionID: String
    ) async throws -> ChatSessionLaunchResult {
        launches.append((action, sessionID))
        launchStarted += 1
        let waiters = launchStartWaiters
        launchStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let launchReleaseGate {
            await launchReleaseGate.wait()
            self.launchReleaseGate = nil
        }
        return launchResult ?? ChatSessionLaunchResult(action: action, parentSessionID: sessionID)
    }

    func holdLaunches() -> TestAsyncGate {
        let gate = TestAsyncGate()
        launchReleaseGate = gate
        return gate
    }

    func waitForLaunchStart() async {
        guard launchStarted == 0 else { return }
        await withCheckedContinuation { continuation in
            launchStartWaiters.append(continuation)
        }
    }

    func setLaunchResult(
        _ result: ChatSessionLaunchResult,
        adding descriptor: ChatSessionDescriptor
    ) {
        launchResult = result
        sessionDescriptors.append(descriptor)
    }

    func session(sessionID: String) async throws -> ChatSessionDescriptor {
        sessionRequests.append(sessionID)
        guard let descriptor = sessionDescriptors.first(where: { $0.id == sessionID }) else {
            throw FakeError.missingSession
        }
        return descriptor
    }

    func controls(sessionID: String) async throws -> ChatSessionControls {
        guard let descriptor = sessionDescriptors.first(where: { $0.id == sessionID }) else {
            throw FakeError.missingSession
        }
        let controls = descriptor.controls
        controlsStarted += 1
        let waiters = controlsStartWaiters
        controlsStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let controlsReleaseGate {
            await controlsReleaseGate.wait()
            self.controlsReleaseGate = nil
        }
        return controls
    }

    func updateControls(_ controls: ChatSessionControls, sessionID: String) async throws -> ChatSessionControls {
        guard let index = sessionDescriptors.firstIndex(where: { $0.id == sessionID }) else {
            throw FakeError.missingSession
        }
        sessionDescriptors[index].controls = controls
        return controls
    }

    func holdControls() -> TestAsyncGate {
        let gate = TestAsyncGate()
        controlsReleaseGate = gate
        return gate
    }

    func waitForControlsStart() async {
        guard controlsStarted == 0 else { return }
        await withCheckedContinuation { continuation in
            controlsStartWaiters.append(continuation)
        }
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
        sentAttachments.append(attachments)
        sendStarted += 1
        let waiters = sendStartWaiters
        sendStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let sendReleaseGate {
            await sendReleaseGate.wait()
            self.sendReleaseGate = nil
        }
    }

    func holdSends() -> TestAsyncGate {
        let gate = TestAsyncGate()
        sendReleaseGate = gate
        return gate
    }

    func waitForSendStart() async {
        guard sendStarted == 0 else { return }
        await withCheckedContinuation { continuation in
            sendStartWaiters.append(continuation)
        }
    }

    func setFailSends(_ value: Bool) {
        failSends = value
    }

    func interrupt(sessionID: String, hard: Bool) async throws {
        interrupts.append((hard, sessionID))
    }

    func answer(optionIndex: Int, sessionID: String) async throws {
        answers.append((optionIndex, sessionID))
        answerStarted += 1
        let waiters = answerStartWaiters
        answerStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let answerReleaseGate {
            await answerReleaseGate.wait()
            self.answerReleaseGate = nil
        }
    }

    func holdAnswers() -> TestAsyncGate {
        let gate = TestAsyncGate()
        answerReleaseGate = gate
        return gate
    }

    func waitForAnswerStart() async {
        guard answerStarted == 0 else { return }
        await withCheckedContinuation { continuation in
            answerStartWaiters.append(continuation)
        }
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

private actor TestAsyncGate {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

private enum FakeError: Error {
    case missingSession
    case sendFailed
}
