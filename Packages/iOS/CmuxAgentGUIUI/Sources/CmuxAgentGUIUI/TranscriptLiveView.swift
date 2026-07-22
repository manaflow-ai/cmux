#if os(iOS)
public import CMUXMobileCore
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxAgentGUIProjection
public import CmuxAgentReplica
public import CmuxAgentSync
import CmuxAgentWire
public import SwiftUI

/// Live chronological conversation surface with its own transcript, composer,
/// keyboard geometry, and scroll-edge ownership.
public struct TranscriptLiveView: View {
    private let engine: AgentSyncEngine
    private let sessionID: AgentSessionID
    private let terminalTheme: TerminalTheme
    private let terminalThemeGeneration: UInt64
    private let density: TranscriptDensity
    private let onShowTerminal: () -> Void

    @State private var input = TranscriptProjectionInput(entries: [])
    @State private var driver: TranscriptProjectionDriver?
    @State private var followState: ConversationFollowState<String> = .followingTail
    @State private var scrollCommand: ConversationScrollCommand?
    @State private var scrollGeneration = 0
    @State private var prefetchResetGeneration = 0
    @State private var historyLoadFailure: AgentHistoryLoadFailure?
    @State private var lastStableFollowState: ConversationFollowState<String> = .followingTail
    @State private var historyLifecycleGeneration = 0
    @Binding private var draft: String
    @State private var selectedSheet: AgentTranscriptSheet?
    @State private var answeringAskID: String?
    @State private var askError: String?
    @State private var markdownRenderer = ChatMarkdownRenderer()
    @State private var contentCache = ChatContentCache()
    @State private var capabilityReport: GuiCapabilitiesResult?
    @State private var capabilityReportSessionVersion: UInt64?

    private var driverKey: TranscriptLiveDriverKey {
        TranscriptLiveDriverKey(engine: engine, sessionID: sessionID)
    }

    public init(
        engine: AgentSyncEngine,
        sessionID: AgentSessionID,
        terminalTheme: TerminalTheme,
        terminalThemeGeneration: UInt64,
        density: TranscriptDensity,
        draft: Binding<String>,
        onShowTerminal: @escaping () -> Void = {}
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.terminalTheme = terminalTheme
        self.terminalThemeGeneration = terminalThemeGeneration
        self.density = density
        _draft = draft
        self.onShowTerminal = onShowTerminal
    }

    public var body: some View {
        let theme = AgentGUITheme(terminalTheme: terminalTheme)
        let appearance = AgentTranscriptAppearance(theme: theme, density: density)
        let projection = TranscriptProjector().project(input)
        let syncPresentation = TranscriptSyncPresentation(
            phase: engine.connectivity.phase,
            consecutiveFailures: engine.connectivity.consecutiveFailureCount,
            input: input
        )
        let adaptedRows = AgentTranscriptRenderAdapter().rows(from: projection.rows)
        let rows = adaptedRows.isEmpty && syncPresentation.showsPlaceholderRow
            ? [AgentTranscriptRenderRow(id: "empty-state", content: .empty(syncPresentation))]
            : adaptedRows

        ConversationKeyboardContainer {
            VStack(spacing: 0) {
                AgentSyncInsetBanner(
                    presentation: syncPresentation,
                    phase: engine.connectivity.phase,
                    historyLoadFailed: historyLoadFailure != nil,
                    theme: theme,
                    retrySync: engine.retryNow,
                    retryHistory: retryHistoryLoad
                )
                ZStack(alignment: .bottomTrailing) {
                    NativeConversationTranscript(
                        rows: rows,
                        hasMoreBefore: input.hasMoreBefore,
                        hasMoreAfter: input.hasMoreAfter,
                        followState: $followState,
                        command: scrollCommand,
                        renderGeneration: Int(truncatingIfNeeded: terminalThemeGeneration),
                        isActive: selectedSheet == nil,
                        beforePageID: input.startCursor?.rawValue,
                        afterPageID: input.endCursor?.rawValue,
                        prefetchResetGeneration: prefetchResetGeneration,
                        onLoadBefore: loadOlder,
                        onLoadAfter: loadNewer,
                        onSemanticHead: jumpToHead,
                        onSemanticTail: jumpToTail
                    ) { row in
                        AgentTranscriptRowView(
                            row: row,
                            theme: theme,
                            density: density,
                            onOpenAsk: openAsk,
                            onOpenActivity: openActivity,
                            onOpenFailedTicket: { selectedSheet = .failedTicket($0) },
                            onRetrySync: engine.retryNow,
                            onShowTerminal: onShowTerminal,
                            onShowCodeBlock: showCodeBlock
                        )
                    }
                    if case .detached(_, _, let unseenCount) = followState {
                        ScrollToBottomPill(theme: theme, unreadCount: unseenCount, action: requestTail)
                            .padding(.trailing, 12)
                            .padding(.bottom, 10)
                    }
                }
            }
        } composer: {
            ChatComposerView(
                agentState: agentState,
                agentKind: agentKind,
                isConnected: isConnected,
                capabilities: composerCapabilities,
                draft: $draft,
                onSend: { text, _ in send(text) },
                onInterrupt: interrupt,
                onOpenTerminal: onShowTerminal
            )
        }
        .environment(\.chatTheme, appearance.chatTheme)
        .environment(\.chatMarkdownRenderer, markdownRenderer)
        .environment(\.chatContentCache, contentCache)
        .environment(\.colorScheme, appearance.colorScheme)
        .background(Color(theme.background))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(item: $selectedSheet) { sheet in
            switch sheet {
            case .ask(let ask):
                AgentAskSheet(
                    ask: ask,
                    theme: theme,
                    canAnswer: canAnswer,
                    isAnswering: answeringAskID == ask.id,
                    errorMessage: askError,
                    onAnswer: { answer(ask, choice: $0) },
                    onShowTerminal: onShowTerminal
                )
            case .activity(let details):
                TranscriptActivityTimelineView(details: details, terminalTheme: terminalTheme)
            case .codeBlock(let selection):
                ChatCodeBlockDetailSheet(
                    id: selection.id,
                    code: selection.code,
                    language: selection.language
                )
            case .failedTicket(let ticket):
                AgentSendFailureSheet(
                    ticket: ticket,
                    theme: theme,
                    retry: {
                        if engine.retrySend(sessionID: sessionID, ticketID: ticket.id) {
                            selectedSheet = nil
                            requestTail()
                        }
                    },
                    showTerminal: onShowTerminal
                )
            }
        }
        .onAppear(perform: startDriverIfNeeded)
        .onDisappear(perform: stopDriver)
        .task(id: capabilityRequestKey) {
            await refreshCapabilities()
        }
        .onChange(of: driverKey) { _, _ in restartDriver() }
        .onChange(of: followState) { _, nextState in
            switch nextState {
            case .followingTail, .detached:
                lastStableFollowState = nextState
            case .jumpingToHead, .jumpingToTail:
                break
            }
        }
        .onChange(of: input.asks) { _, asks in
            guard case .ask(let selectedAsk) = selectedSheet,
                  AgentAskSheetPolicy.shouldDismiss(selectedAskID: selectedAsk.id, asks: asks)
            else { return }
            selectedSheet = nil
            answeringAskID = nil
            askError = nil
        }
    }

    private var session: AgentSessionSnapshot? {
        engine.directory.sessions.first { $0.id == sessionID }
    }

    private var agentState: ChatAgentState {
        switch session?.phase ?? input.sessionPhase {
        case .starting, .working: .working(since: .now)
        case .needsInput: .needsInput(since: .now)
        case .ended: .ended
        case .idle, .unknown: .idle
        }
    }

    private var agentKind: ChatAgentKind {
        ChatAgentKind(source: session?.kind.rawValue ?? "agent")
    }

    private var isConnected: Bool {
        if case .connected = engine.connectivity.phase { return true }
        return false
    }

    private var capabilityRequestKey: AgentCapabilityRequestKey {
        AgentCapabilityRequestKey(
            sessionID: sessionID,
            sessionVersion: session?.version.rawValue ?? 0,
            isConnected: isConnected
        )
    }

    private var interactionCapabilities: AgentSessionInteractionCapabilities {
        let currentVersion = session?.version.rawValue
        let currentReport = capabilityReportSessionVersion == currentVersion ? capabilityReport : nil
        return AgentSessionInteractionCapabilities(report: currentReport, tier: session?.tier)
    }

    private var canSteer: Bool {
        interactionCapabilities.canSteer
    }

    private var canAnswer: Bool {
        isConnected && interactionCapabilities.canAnswer
    }

    private var composerCapabilities: ChatComposerCapabilities {
        guard canSteer else { return .readOnly }
        return ChatComposerCapabilities(
            allowsAttachments: false,
            allowsInterrupt: isConnected,
            allowsHardInterrupt: isConnected,
            allowsOfflineSendQueue: true
        )
    }

    private func startDriverIfNeeded() {
        guard driver == nil else { return }
        let nextDriver = TranscriptProjectionDriver(engine: engine, sessionID: sessionID) { nextInput in
            input = nextInput
        }
        driver = nextDriver
        nextDriver.start()
    }

    private func stopDriver() {
        historyLifecycleGeneration &+= 1
        driver?.stop()
        driver = nil
    }

    private func refreshCapabilities() async {
        guard isConnected else { return }
        let lifecycleGeneration = historyLifecycleGeneration
        let requestedSessionVersion = session?.version.rawValue
        do {
            let report = try await engine.capabilities(sessionID: sessionID)
            guard lifecycleGeneration == historyLifecycleGeneration,
                  requestedSessionVersion == session?.version.rawValue
            else { return }
            capabilityReport = report
            capabilityReportSessionVersion = requestedSessionVersion
        } catch {
            // Directory tier remains the conservative fallback until the next
            // connection or session revision triggers another capability pull.
        }
    }

    private func restartDriver() {
        stopDriver()
        input = TranscriptProjectionInput(entries: [])
        followState = .followingTail
        lastStableFollowState = .followingTail
        historyLoadFailure = nil
        capabilityReport = nil
        capabilityReportSessionVersion = nil
        prefetchResetGeneration += 1
        startDriverIfNeeded()
    }

    private func loadOlder() {
        historyLoadFailure = nil
        let lifecycleGeneration = historyLifecycleGeneration
        Task { @MainActor in
            do {
                try await engine.loadOlder(sessionID: sessionID)
            } catch {
                guard lifecycleGeneration == historyLifecycleGeneration else { return }
                historyLoadFailure = .older
                prefetchResetGeneration += 1
            }
        }
    }

    private func loadNewer() {
        historyLoadFailure = nil
        let lifecycleGeneration = historyLifecycleGeneration
        Task { @MainActor in
            do {
                try await engine.loadNewer(sessionID: sessionID)
            } catch {
                guard lifecycleGeneration == historyLifecycleGeneration else { return }
                historyLoadFailure = .newer
                prefetchResetGeneration += 1
            }
        }
    }

    private func jumpToHead() {
        historyLoadFailure = nil
        let lifecycleGeneration = historyLifecycleGeneration
        Task { @MainActor in
            do {
                try await engine.jumpToHead(sessionID: sessionID)
            } catch {
                guard lifecycleGeneration == historyLifecycleGeneration else { return }
                historyLoadFailure = .head
                followState = lastStableFollowState
                return
            }
            requestScroll(.head)
        }
    }

    private func jumpToTail() {
        historyLoadFailure = nil
        let lifecycleGeneration = historyLifecycleGeneration
        Task { @MainActor in
            do {
                try await engine.jumpToTail(sessionID: sessionID)
            } catch {
                guard lifecycleGeneration == historyLifecycleGeneration else { return }
                historyLoadFailure = .tail
                followState = lastStableFollowState
                return
            }
            requestScroll(.tail)
        }
    }

    private func retryHistoryLoad() {
        guard let historyLoadFailure else { return }
        switch historyLoadFailure {
        case .older:
            loadOlder()
        case .newer:
            loadNewer()
        case .head:
            followState = .jumpingToHead
            jumpToHead()
        case .tail:
            followState = .jumpingToTail
            jumpToTail()
        }
    }

    private func requestTail() {
        followState = .jumpingToTail
        jumpToTail()
    }

    private func requestScroll(_ target: ConversationScrollTarget) {
        scrollGeneration += 1
        scrollCommand = ConversationScrollCommand(generation: scrollGeneration, target: target)
    }

    private func send(_ text: String) {
        guard canSteer else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        engine.send(sessionID: sessionID, text: trimmed)
        followState = .followingTail
        requestScroll(.tail)
    }

    private func interrupt(hard: Bool) {
        guard canSteer, isConnected else { return }
        Task { try? await engine.interrupt(sessionID: sessionID, hard: hard) }
    }

    private func openActivity(_ details: TranscriptActivityDetails) {
        selectedSheet = .activity(details)
    }

    private func openAsk(_ ask: PendingAsk) {
        let previousAskID: String? = if case .ask(let selectedAsk) = selectedSheet {
            selectedAsk.id
        } else {
            nil
        }
        if AgentAskSheetPolicy.shouldResetError(previousAskID: previousAskID, nextAskID: ask.id) {
            askError = nil
        }
        selectedSheet = .ask(ask)
    }

    private func showCodeBlock(messageID: String, segmentIndex: Int) {
        let rows = AgentTranscriptRenderAdapter().rows(from: TranscriptProjector().project(input).rows)
        guard let message = rows.compactMap({ row -> ChatMessage? in
            guard case .message(let snapshot) = row.content,
                  snapshot.message.id == messageID
            else { return nil }
            return snapshot.message
        }).first,
        case .prose(let prose) = message.kind,
        let segment = contentCache
            .proseSegments(messageID: messageID, text: prose.text)
            .first(where: { $0.index == segmentIndex }),
        case .code(let language) = segment.kind
        else { return }
        selectedSheet = .codeBlock(AgentCodeBlockSelection(
            id: "code-\(messageID)-\(segmentIndex)",
            code: segment.content,
            language: language
        ))
    }

    private func answer(_ ask: PendingAsk, choice: Int) {
        guard canAnswer,
              answeringAskID == nil,
              ask.options.indices.contains(choice)
        else { return }
        answeringAskID = ask.id
        askError = nil
        Task { @MainActor in
            defer { answeringAskID = nil }
            do {
                try await engine.answer(sessionID: sessionID, askID: ask.id, choice: choice)
                selectedSheet = nil
            } catch {
                askError = AgentGUIL10n.string(
                    "agent.ask.failed",
                    defaultValue: "The answer could not be sent. Try again or use Terminal."
                )
            }
        }
    }
}
#endif
