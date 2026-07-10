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
    private var removalVersions: [AgentSessionID: UInt64] = [:]
    private var subscriptionObserver: NSObjectProtocol?
    private let hookTapStream: AsyncStream<WorkstreamEvent>
    private nonisolated let hookTapContinuation: AsyncStream<WorkstreamEvent>.Continuation
    private var hookTapTask: Task<Void, Never>?
    private var started = false

    init(
        macDeviceID: String = MobileHostIdentity.deviceID(),
        clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1_000) },
        terminalInjector: (any AgentGUITerminalInjecting)? = nil
    ) {
        self.epoch = ReplicaEpoch(rawValue: UUID().uuidString)
        self.macDeviceID = MacDeviceID(rawValue: macDeviceID)
        self.reducer = AgentTruthReducer(macDeviceID: self.macDeviceID)
        self.publisher = AgentGUIWirePublisher(epoch: epoch)
        self.clock = clock
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
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateGates()
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
        Task { @MainActor in
            exitWatcher?.stopAll()
            processSource?.setRunning(false)
            reevaluationTimer?.cancel()
            hookTapContinuation.finish()
            hookTapTask?.cancel()
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

    func sessionsResult() -> GuiSessionsResult {
        GuiSessionsResult(epoch: epoch, sessions: reducer.snapshots.values.sorted { $0.lastActivityHint > $1.lastActivityHint })
    }

    func sessionResult(id: AgentSessionID) throws -> GuiSessionResult {
        guard let session = reducer.snapshots[id] else {
            throw AgentGUIRPCError.notFound
        }
        return GuiSessionResult(epoch: epoch, session: session)
    }

    func entriesResult(params: GuiEntriesParams) async throws -> GuiEntriesResult {
        guard let pipeline = pipelines[params.sessionID] else {
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
        guard let evidence = reducer.evidence[params.sessionID] else {
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
        let snapshot = reducer.snapshots[params.sessionID]
        guard snapshot != nil else {
            throw AgentGUIRPCError.notFound
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

    func interruptResult(params: GuiInterruptParams) throws -> GuiInterruptResult {
        guard let snapshot = reducer.snapshots[params.sessionID] else {
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
            let knownSessionID = sessionID(for: observation)
            let activityHint = reducer.snapshots[knownSessionID]?.lastActivityHint ?? currentActivityHintMS()
            fold(.processObserved(observation, tick: activityHint))
            exitWatcher?.watch(pid: observation.pid, startTick: observation.startTick)
            let sessionID = sessionID(for: observation)
            ensurePipeline(
                sessionID: sessionID,
                kindHint: observation.agentKindGuess,
                transcriptPath: observation.openTranscriptPath,
                cwd: observation.cwd
            )
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
        ensurePipeline(sessionID: fact.sessionID, kindHint: AgentKind(rawValue: event.source), transcriptPath: fact.transcriptPath, cwd: fact.cwd)
        updateGates()
    }

    private func sessionID(for observation: ProcessObservation) -> AgentSessionID {
        reducer.evidence.first { _, evidence in
            guard let identity = evidence.processIdentity else { return false }
            return identity.pid == observation.pid
        }?.key ?? reducer.snapshots.values.first { snapshot in
            snapshot.surfaceID == observation.surfaceID
        }?.id ?? AgentSessionID(rawValue: "process:\(observation.pid):\(observation.startTick)")
    }

    private func ensurePipeline(sessionID: AgentSessionID, kindHint: AgentKind, transcriptPath: String?, cwd: String?) {
        let snapshot = reducer.snapshots[sessionID]
        let kind = snapshot?.kind ?? kindHint
        let evidencePath = transcriptPath ?? reducer.evidence[sessionID]?.transcriptPath
        guard let path = transcriptResolver.transcriptPath(sessionID: sessionID, kind: kind, cwd: cwd ?? snapshot?.cwd, evidencePath: evidencePath) else {
            return
        }
        if pipelines[sessionID] == nil {
            pipelines[sessionID] = AgentGUIJournalPipeline(sessionID: sessionID, kind: kind, path: path)
            if let pipeline = pipelines[sessionID] {
                Task { [weak self] in
                    let events = await pipeline.ingestInitial()
                    await MainActor.run {
                        guard let self else { return }
                        self.handleJournalEvents(events, sessionID: sessionID)
                    }
                }
            }
        }
    }

    private func fold(_ signal: TruthChannelSignal) {
        for change in reducer.fold(signal) {
            switch change {
            case .sessionUpserted(let session):
                publisher.publishSessionUpserted(session)
                sendLedgers[session.id]?.handleSessionSnapshot(session)
                askRegistry.handleSessionSnapshot(session)
            case .sessionRemoved(let sessionID):
                sendLedgers.removeValue(forKey: sessionID)
                askRegistry.removeSession(sessionID)
                let version = nextRemovalVersion(sessionID: sessionID)
                publisher.publishSessionRemoved(sessionID, version: EntityVersion(rawValue: version))
            }
        }
    }

    private func updateGates() {
        let nowTick = currentActivityHintMS()
        expirePendingAgentGUIState(now: nowTick)
        let hasSessionSubscribers = MobileHostService.hasEventSubscribers(topic: GuiWireTopic.sessions)
        let hasLiveRecent = reducer.snapshots.values.contains {
            AgentGUISubscriptionPolicy.isLiveOrRecentlyActive($0, nowMS: nowTick)
        }
        processSource?.setRunning(AgentGUISubscriptionPolicy.shouldRunObservation(
            hasSessionSubscribers: hasSessionSubscribers,
            hasLiveRecentSession: hasLiveRecent
        ))
        for (sessionID, pipeline) in pipelines {
            let topic = GuiWireTopic.journal(sessionID: sessionID)
            let shouldRun = AgentGUISubscriptionPolicy.shouldRunJournal(
                hasJournalSubscribers: MobileHostService.hasEventSubscribers(topic: topic),
                session: reducer.snapshots[sessionID],
                nowMS: nowTick
            )
            pipeline.setWatching(shouldRun) { [weak self] events in
                guard let self else { return }
                self.handleJournalEvents(events, sessionID: sessionID)
            }
        }
        updateReevaluationTimer(hasRunningSessions: reducer.snapshots.values.contains { $0.phase != .ended } || hasPendingAgentGUIExpirations)
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
        if let snapshot = reducer.snapshots[sessionID] {
            ledger.handleSessionSnapshot(snapshot)
        }
        sendLedgers[sessionID] = ledger
        return ledger
    }
}
