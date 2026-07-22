import CMUXAgentLaunch
import CmuxAgentReplica
import CmuxAgentTruthKit
import CmuxAgentWire
import Foundation

@MainActor
final class AgentGUIService {
    // Assigned once during app startup before control-socket requests can arrive.
    nonisolated(unsafe) static private(set) var shared: AgentGUIService?

    let epoch: ReplicaEpoch
    let macDeviceID: MacDeviceID
    private let reducer: AgentTruthReducer
    private let publisher: AgentGUIWirePublisher
    private let clock: () -> Int
    private let hasEventSubscribers: (String) -> Bool
    private let terminalInjector: any AgentGUITerminalInjecting
    private let hookMapper = AgentGUIHookFactMapper()
    private let transcriptResolver = AgentGUITranscriptResolver()
    private let capabilityBuilder = CapabilityReportBuilder()
    private let capabilityMapper = AgentGUICapabilityMapper()
    private var processSource: AgentProcessObservationSource?
    private var exitWatcher: AgentProcessExitWatcher?
    private var reevaluationTimer: DispatchSourceTimer?
    private var pipelines: [AgentSessionID: AgentGUIJournalPipeline] = [:]
    private var sendLedgers: [AgentSessionID: AgentGUISendLedger] = [:]
    private let askRegistry: AgentGUIAskRegistry
    private let incrementalState = AgentGUIIncrementalState()
    private var streamProducer: AgentGUIStreamProducer?
    private var removalVersions: [AgentSessionID: UInt64] = [:]
    private var subscriptionObserver: NSObjectProtocol?
    private let hookTapStream: AsyncStream<WorkstreamEvent>
    private nonisolated let hookTapContinuation: AsyncStream<WorkstreamEvent>.Continuation
    private var hookTapTask: Task<Void, Never>?
    private var started = false

    init(
        macDeviceID: String = MobileHostIdentity.deviceID(),
        clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1_000) },
        terminalInjector: (any AgentGUITerminalInjecting)? = nil,
        hasEventSubscribers: @escaping (String) -> Bool = { topic in
            MobileHostService.hasEventSubscribers(topic: topic)
        }
    ) {
        self.epoch = ReplicaEpoch(rawValue: UUID().uuidString)
        self.macDeviceID = MacDeviceID(rawValue: macDeviceID)
        self.reducer = AgentTruthReducer(macDeviceID: self.macDeviceID)
        self.publisher = AgentGUIWirePublisher(epoch: epoch)
        self.clock = clock
        self.hasEventSubscribers = hasEventSubscribers
        let resolvedTerminalInjector = terminalInjector ?? AgentGUITerminalInjector()
        self.terminalInjector = resolvedTerminalInjector
        self.askRegistry = AgentGUIAskRegistry(
            clock: clock,
            injector: resolvedTerminalInjector,
            publish: { [publisher] ask in
                publisher.publishAskState(ask)
            }
        )
        let hookTap = AsyncStream<WorkstreamEvent>.makeStream()
        self.hookTapStream = hookTap.stream
        self.hookTapContinuation = hookTap.continuation
        self.streamProducer = AgentGUIStreamProducer(
            publish: { [publisher] sessionID, event in
                publisher.publishStreamTick(event, sessionID: sessionID)
            },
            snapshot: { surfaceID in
                GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID)?
                    .mobileRenderGridFrame(stateSeq: 0, full: true)?.rows
            },
            hasSubscribers: { sessionID in
                hasEventSubscribers(GuiWireTopic.journal(sessionID: sessionID))
            },
            context: { [weak self] sessionID in
                guard let window = self?.pipelines[sessionID]?.window else { return nil }
                return AgentGUIStreamProducer.Context(journalID: window.journalID, afterSeq: window.tailSeq)
            }
        )
    }

    func start() {
        guard !started else { return }
        started = true
        Self.shared = self
        processSource = AgentProcessObservationSource { [weak self] observations in
            self?.handleProcessObservations(observations)
        }
        exitWatcher = AgentProcessExitWatcher { [weak self] pid, startTick in
            self?.fold(.processGone(pid: pid, startTick: startTick, tick: self?.currentActivityHintMS() ?? 0))
        }
        let stream = hookTapStream
        hookTapTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handleHookEventSerial(event)
            }
        }
        subscriptionObserver = NotificationCenter.default.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let changedTopics = notification.userInfo?["topics"] as? [String]
            Task { @MainActor in
                self?.handleSubscriptionChange(changedTopics: changedTopics)
            }
        }
        updateGates()
    }

    deinit {
        let exitWatcher = exitWatcher
        let processSource = processSource
        let reevaluationTimer = reevaluationTimer
        let hookTapContinuation = hookTapContinuation
        let hookTapTask = hookTapTask
        let subscriptionObserver = subscriptionObserver
        let streamProducer = streamProducer
        Task { @MainActor in
            exitWatcher?.stopAll()
            processSource?.setRunning(false)
            reevaluationTimer?.cancel()
            hookTapContinuation.finish()
            hookTapTask?.cancel()
            streamProducer?.stopAll()
            if let subscriptionObserver {
                NotificationCenter.default.removeObserver(subscriptionObserver)
            }
        }
    }

    nonisolated func handleHookEvent(_ event: WorkstreamEvent) {
        hookTapContinuation.yield(event)
    }

    func forceProcessScan() {
        processSource?.scanNow()
    }

    #if DEBUG
    func ingestProcessObservationsForTesting(_ observations: [ProcessObservation]) {
        handleProcessObservations(observations)
    }

    func refreshSubscriptionsForTesting(changedTopics: [String]) {
        handleSubscriptionChange(changedTopics: changedTopics)
    }

    var journalPipelineCountForTesting: Int {
        pipelines.count
    }

    var watchingJournalPipelineCountForTesting: Int {
        pipelines.values.count(where: \.isWatching)
    }
    #endif

    func sessionsResult() -> GuiSessionsResult {
        GuiSessionsResult(epoch: epoch, sessions: reducer.snapshots.values.sorted { $0.lastActivityHint > $1.lastActivityHint })
    }

    func sessionResult(id: AgentSessionID) throws -> GuiSessionResult {
        guard let session = reducer.snapshot(for: id) else {
            throw AgentGUIRPCError.notFound
        }
        return GuiSessionResult(epoch: epoch, session: session)
    }

    func entriesResult(params: GuiEntriesParams) async throws -> GuiEntriesResult {
        guard let pipeline = ensurePipeline(sessionID: params.sessionID) else {
            throw AgentGUIRPCError.notFound
        }
        let initialEvents = await pipeline.ingestInitial()
        handleJournalEvents(initialEvents, sessionID: params.sessionID)
        let limit = max(1, min(params.limit, AgentGUIConstants.maxEntriesLimit))
        guard let page = pipeline.entries(beforeSeq: params.beforeSeq, afterSeq: params.afterSeq, limit: limit) else {
            throw AgentGUIRPCError.notFound
        }
        if let expected = params.journalID, expected != page.journalID {
            throw AgentGUIRPCError.notFound
        }
        return GuiEntriesResult(
            journalID: page.journalID,
            entries: page.entries,
            windowStart: page.windowStart,
            windowEnd: page.windowEnd,
            tailSeq: page.tailSeq,
            hasMoreBefore: page.hasMoreBefore
        )
    }

    func capabilitiesResult(params: GuiCapabilitiesParams) throws -> GuiCapabilitiesResult {
        guard let evidence = reducer.evidence(for: params.sessionID) else {
            throw AgentGUIRPCError.notFound
        }
        let report = capabilityBuilder.report(for: evidence)
        return GuiCapabilitiesResult(
            tier: report.tier,
            reasons: report.reasons.map { capabilityMapper.map($0) },
            cliVersion: nil,
            steerable: report.steerable,
            answerable: report.answerable
        )
    }

    func sessionSnapshot(surfaceID: String) -> AgentSessionSnapshot? {
        let matches = reducer.snapshots.values.filter { $0.surfaceID == surfaceID }
        return matches.first(where: { $0.phase != .ended }) ?? matches.first
    }
    func submitCmuxOwnedPrompt(surfaceID: String, text: String) -> AgentLaunchExecutionResult {
        guard let snapshot = sessionSnapshot(surfaceID: surfaceID), snapshot.phase != .ended else {
            return launchExecutionResult(terminalInjector.submitPrompt(surfaceID: surfaceID, text: text))
        }
        do {
            let result = try ledger(sessionID: snapshot.id).submit(
                ticketID: UUID(),
                text: text,
                attachmentCount: 0,
                snapshot: snapshot
            )
            updateGates()
            return result.queuedOnMac ? .queued : .accepted
        } catch let error as AgentGUIRPCError {
            return .failed(error.code)
        } catch {
            return .failed("prompt_injection_failed")
        }
    }
    /// Wire attachment descriptors are rejected with `send_rejected` and `attachment_unsupported` until binary transfer is implemented.
    func sendResult(params: GuiSendParams) throws -> GuiSendResult {
        guard let ticketID = UUID(uuidString: params.ticketID) else {
            throw AgentGUIRPCError.invalidParams
        }
        let attachments = params.attachments ?? []
        guard attachments.isEmpty else {
            throw AgentGUIRPCError.sendRejected(detail: "attachment_unsupported")
        }
        let text = params.text ?? ""
        guard !text.isEmpty else {
            throw AgentGUIRPCError.invalidParams
        }
        guard let snapshot = reducer.snapshot(for: params.sessionID),
              let evidence = reducer.evidence(for: params.sessionID) else {
            throw AgentGUIRPCError.notFound
        }
        guard capabilityBuilder.report(for: evidence).steerable else {
            throw AgentGUIRPCError.sendRejected(detail: "session_not_steerable")
        }
        let result = try ledger(sessionID: params.sessionID).submit(
            ticketID: ticketID,
            text: text,
            attachmentCount: attachments.count,
            snapshot: snapshot
        )
        updateGates()
        return result
    }

    private func launchExecutionResult(
        _ result: AgentGUITerminalInjectionResult
    ) -> AgentLaunchExecutionResult {
        switch result {
        case .accepted:
            .accepted
        case .bindingLost:
            .failed("binding_lost")
        case .inputQueueFull:
            .failed("input_queue_full")
        case .processExited:
            .failed("process_exited")
        }
    }
    func interruptResult(params: GuiInterruptParams) throws -> GuiInterruptResult {
        guard let snapshot = reducer.snapshot(for: params.sessionID) else {
            throw AgentGUIRPCError.notFound
        }
        guard let surfaceID = snapshot.surfaceID, !surfaceID.isEmpty else {
            throw AgentGUIRPCError.bindingLost
        }
        let result = terminalInjector.sendKey(surfaceID: surfaceID, keyName: params.hard ? "ctrl+c" : "escape")
        guard result.accepted else {
            throw AgentGUIRPCError.fromInjectionFailure(result)
        }
        return GuiInterruptResult(interrupted: true)
    }

    func answerResult(params: GuiAnswerParams) throws -> GuiAnswerResult {
        let result = try askRegistry.answer(params: params)
        updateGates()
        return result
    }

    private func handleProcessObservations(_ observations: [ProcessObservation]) {
        for observation in observations {
            let knownSessionID = incrementalState.sessionID(pid: observation.pid, startTick: observation.startTick)
            let activityHint = knownSessionID.flatMap { reducer.snapshot(for: $0)?.lastActivityHint }
                ?? currentActivityHintMS()
            let changedSessionID = fold(.processObserved(observation, tick: activityHint))
            exitWatcher?.watch(pid: observation.pid, startTick: observation.startTick)
            guard let sessionID = changedSessionID ?? knownSessionID else { continue }
            incrementalState.bindProcess(pid: observation.pid, startTick: observation.startTick, to: sessionID)
            ensurePipelineIfDemanded(sessionID: sessionID)
        }
        updateGates()
    }

    func handleHookEventSerial(_ event: WorkstreamEvent) {
        let tick = currentActivityHintMS()
        if let wrapperFact = hookMapper.wrapperLaunchFact(from: event) {
            fold(.wrapperLaunched(wrapperFact, tick: tick))
        }
        let fact = hookMapper.hookFact(from: event)
        fold(.hookEvent(fact, tick: tick))
        ensurePipelineIfDemanded(sessionID: fact.sessionID)
        switch event.hookEventName {
        case .userPromptSubmit:
            if let snapshot = reducer.snapshot(for: fact.sessionID),
               let rawSurfaceID = snapshot.surfaceID,
               let surfaceID = UUID(uuidString: rawSurfaceID) {
                streamProducer?.turnStarted(sessionID: fact.sessionID, surfaceID: surfaceID, agentKind: snapshot.kind)
            }
        case .stop, .sessionEnd:
            streamProducer?.turnEnded(sessionID: fact.sessionID)
        default:
            break
        }
        updateGates()
    }

    private func handleSubscriptionChange(changedTopics: [String]?) {
        for topic in changedTopics ?? [] where topic.hasPrefix(GuiWireTopic.journalPrefix) {
            let rawSessionID = String(topic.dropFirst(GuiWireTopic.journalPrefix.count))
            guard !rawSessionID.isEmpty else { continue }
            let sessionID = AgentSessionID(rawValue: rawSessionID)
            ensurePipelineIfDemanded(sessionID: sessionID)
        }
        updateGates()
    }

    private func ensurePipelineIfDemanded(sessionID: AgentSessionID) {
        let topic = GuiWireTopic.journal(sessionID: sessionID)
        guard hasEventSubscribers(topic) else { return }
        _ = ensurePipeline(sessionID: sessionID)
    }

    private func ensurePipeline(sessionID: AgentSessionID) -> AgentGUIJournalPipeline? {
        if let pipeline = pipelines[sessionID] {
            return pipeline
        }
        guard let snapshot = reducer.snapshot(for: sessionID) else { return nil }
        let evidencePath = reducer.evidence(for: sessionID)?.transcriptPath
        guard let path = transcriptResolver.transcriptPath(
            sessionID: sessionID,
            kind: snapshot.kind,
            cwd: snapshot.cwd,
            evidencePath: evidencePath
        ) else {
            return nil
        }
        let pipeline = AgentGUIJournalPipeline(sessionID: sessionID, kind: snapshot.kind, path: path)
        pipelines[sessionID] = pipeline
        Task { @MainActor [weak self, weak pipeline] in
            guard let pipeline else { return }
            let events = await pipeline.ingestInitial()
            guard let self else { return }
            self.handleJournalEvents(events, sessionID: sessionID)
        }
        return pipeline
    }

    private func indexProcessIdentity(for sessionID: AgentSessionID) {
        guard let identity = reducer.evidence(for: sessionID)?.processIdentity,
              let startTick = identity.startTick else {
            return
        }
        incrementalState.bindProcess(pid: identity.pid, startTick: startTick, to: sessionID)
    }

    @discardableResult
    private func fold(_ signal: TruthChannelSignal) -> AgentSessionID? {
        var changedSessionID: AgentSessionID?
        for change in reducer.fold(signal) {
            switch change {
            case .sessionUpserted(let session):
                changedSessionID = session.id
                incrementalState.updateSession(session)
                indexProcessIdentity(for: session.id)
                publisher.publishSessionUpserted(session)
                sendLedgers[session.id]?.handleSessionSnapshot(session)
                askRegistry.handleSessionSnapshot(session)
            case .sessionRemoved(let sessionID):
                incrementalState.removeSession(sessionID)
                streamProducer?.turnEnded(sessionID: sessionID)
                sendLedgers.removeValue(forKey: sessionID)
                askRegistry.removeSession(sessionID)
                if let pipeline = pipelines.removeValue(forKey: sessionID) {
                    pipeline.setWatching(false) { _ in }
                }
                let version = nextRemovalVersion(sessionID: sessionID)
                publisher.publishSessionRemoved(sessionID, version: EntityVersion(rawValue: version))
            }
        }
        return changedSessionID
    }

    private func updateGates() {
        let nowTick = currentActivityHintMS()
        expirePendingAgentGUIState(now: nowTick)
        let hasSessionSubscribers = hasEventSubscribers(GuiWireTopic.sessions)
        let hasLiveRecent = incrementalState.hasLiveOrRecentlyActiveSession(at: nowTick)
        processSource?.setRunning(AgentGUISubscriptionPolicy.shouldRunObservation(
            hasSessionSubscribers: hasSessionSubscribers,
            hasLiveRecentSession: hasLiveRecent
        ))
        for (sessionID, pipeline) in pipelines {
            let topic = GuiWireTopic.journal(sessionID: sessionID)
            let shouldRun = AgentGUISubscriptionPolicy.shouldRunJournal(
                hasJournalSubscribers: hasEventSubscribers(topic)
            )
            pipeline.setWatching(shouldRun) { [weak self] events in
                guard let self else { return }
                self.handleJournalEvents(events, sessionID: sessionID)
            }
        }
        updateReevaluationTimer(hasRunningSessions: incrementalState.hasNonEndedSessions || hasPendingAgentGUIExpirations)
    }

    private func updateReevaluationTimer(hasRunningSessions: Bool) {
        guard hasRunningSessions else {
            reevaluationTimer?.cancel()
            reevaluationTimer = nil
            return
        }
        guard reevaluationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + AgentGUIConstants.gateReevaluationCadence, repeating: AgentGUIConstants.gateReevaluationCadence)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.updateGates()
            }
        }
        reevaluationTimer = timer
        timer.resume()
    }

    private func nextRemovalVersion(sessionID: AgentSessionID) -> UInt64 {
        let next = (removalVersions[sessionID] ?? 0) + 1
        removalVersions[sessionID] = next
        return next
    }

    private func currentActivityHintMS() -> Int {
        clock()
    }

    private var hasPendingAgentGUIExpirations: Bool {
        askRegistry.hasPendingExpirations || sendLedgers.values.contains { $0.hasPendingExpirations }
    }

    private func expirePendingAgentGUIState(now: Int) {
        for ledger in sendLedgers.values {
            ledger.expire(now: now)
        }
        askRegistry.expire(now: now)
    }

    private func handleJournalEvents(_ events: [AgentGUIJournalPipelineEvent], sessionID: AgentSessionID) {
        for event in events {
            streamProducer?.journalEventArrived(
                event,
                sessionID: sessionID,
                window: pipelines[sessionID]?.window
            )
            publisher.publishJournalEvent(event, sessionID: sessionID)
            sendLedgers[sessionID]?.handleJournalEvent(event)
            askRegistry.handleJournalEvent(event, sessionID: sessionID)
        }
    }

    private func ledger(sessionID: AgentSessionID) -> AgentGUISendLedger {
        if let ledger = sendLedgers[sessionID] {
            return ledger
        }
        let ledger = AgentGUISendLedger(
            sessionID: sessionID,
            clock: clock,
            injector: terminalInjector,
            publish: { [publisher] ticket in
                publisher.publishSendState(ticket)
            }
        )
        if let snapshot = reducer.snapshot(for: sessionID) {
            ledger.handleSessionSnapshot(snapshot)
        }
        sendLedgers[sessionID] = ledger
        return ledger
    }
}
