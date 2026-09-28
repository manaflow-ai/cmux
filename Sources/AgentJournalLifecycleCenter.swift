import CmuxAgentJournal
import Foundation
import os

/// App-side owner of the agent journal: the single writer for
/// `agent_journal_append`, the ordered consumer that reduces committed events
/// into sidebar lifecycle state, and the startup replayer that reproduces
/// badges from history instead of the last painted state.
///
/// Ordering: appends commit synchronously on the socket worker (the durable
/// acknowledgement returned to the emitting hook), then flow through one
/// FIFO operation stream alongside restore-alias recording and the startup
/// replay request. The consumer awaits every main-actor application before
/// taking the next operation, so sidebar assignments always apply in journal
/// order — a startup replay can never land after a newer live event's
/// assignment. Derived interrupt events additionally reconcile through the
/// durable store and conditionally append against the captured session
/// generation, covering the socket worker's commit-before-enqueue window.
/// The store itself is opened
/// lazily off-main (see ``AgentJournalLazyStore``), so main-actor callers only
/// ever enqueue.
final class AgentJournalLifecycleCenter: Sendable {
    static let shared = AgentJournalLifecycleCenter()

    private struct InterruptScope: Hashable, Sendable {
        let surfaceId: String
        let agentKey: String
    }

    struct UserInterruptBoundary: Equatable, Sendable {
        let sessionSequences: [String: Int64]
        let observedHeadSequence: Int64
    }

    private struct InterruptSnapshotState: Sendable {
        var boundaries: [InterruptScope: UserInterruptBoundary] = [:]
    }

    private enum Operation: Sendable {
        case ingest(AgentJournalEvent)
        case submit(AgentJournalEventDraft, UUID?)
        case feed(AgentFeedSemanticInput, UUID?)
        case append(AgentJournalEventDraft)
        case requestInterrupt(
            surfaceId: String,
            workspaceId: String,
            agentKey: String,
            source: String,
            boundary: UserInterruptBoundary,
            receipt: AgentJournalOperationReceipt
        )
        case settleInterrupt(
            surfaceId: String,
            workspaceId: String,
            agentKey: String,
            source: String,
            boundary: UserInterruptBoundary,
            receipt: AgentJournalOperationReceipt
        )
        case recordAliases(workspaces: [String: String], surfaces: [String: String])
        case startupReplay

        var admissionID: UUID? {
            switch self {
            case .submit(_, let id), .feed(_, let id): id
            default: nil
            }
        }

        var receipt: AgentJournalOperationReceipt? {
            switch self {
            case .requestInterrupt(_, _, _, _, _, let receipt),
                 .settleInterrupt(_, _, _, _, _, let receipt):
                receipt
            default:
                nil
            }
        }
    }

    private let admissions = AgentNotificationAdmissionWaiters()
    private let interruptSnapshots = OSAllocatedUnfairLock(
        initialState: InterruptSnapshotState()
    )
    private let lazyStore: AgentJournalLazyStore?
    private let operations: AsyncStream<Operation>.Continuation?
    private let consumerTask: Task<Void, Never>?

    convenience init() {
        self.init(databaseURL: Self.defaultDatabaseURL())
    }

    init(
        databaseURL: URL?,
        consumerStart: @escaping @Sendable () async -> Void = {},
        reconciliationCursorDidAdvance: @escaping @Sendable (AgentJournalEvent) -> Void = { _ in },
        reconciliationPageRead: @escaping @Sendable () -> Void = {}
    ) {
        guard let databaseURL else {
            self.lazyStore = nil
            self.operations = nil
            self.consumerTask = nil
            return
        }
        let lazyStore = AgentJournalLazyStore(databaseURL: databaseURL)
        self.lazyStore = lazyStore
        let admissions = self.admissions
        let interruptSnapshots = self.interruptSnapshots
        let channel = AsyncStream<Operation>.makeStream(bufferingPolicy: .unbounded)
        channel.continuation.onTermination = { _ in admissions.finish() }
        self.operations = channel.continuation
        let operationContinuation = channel.continuation
        self.consumerTask = Task.detached(priority: .utility) {
            await consumerStart()
            let reducer = AgentLifecycleReducer()
            let replayPolicy = AgentJournalReplayPolicy()
            var state = AgentLifecycleReducerState()
            var notifications = AgentNotificationReconciler()
            // `state.headSequence` is only the largest sequence observed; it
            // cannot prove that every lower committed row was folded. Socket
            // workers commit before enqueueing, so a later ingress can arrive
            // while an earlier committed row is still missing from the FIFO.
            var reconciledThroughSequence: Int64 = 0
            var reconciledAheadSequences: Set<Int64> = []
            func containsReconciledSequence(_ sequence: Int64) -> Bool {
                sequence <= reconciledThroughSequence || reconciledAheadSequences.contains(sequence)
            }
            func noteReconciledSequence(_ sequence: Int64) {
                guard sequence > reconciledThroughSequence else { return }
                reconciledAheadSequences.insert(sequence)
                while reconciledAheadSequences.remove(reconciledThroughSequence + 1) != nil {
                    reconciledThroughSequence += 1
                }
            }
            func noteReconciledScan(through sequence: Int64) {
                reconciledThroughSequence = max(reconciledThroughSequence, sequence)
                let reconciledFloor = reconciledThroughSequence
                reconciledAheadSequences = reconciledAheadSequences.filter {
                    $0 > reconciledFloor
                }
            }
            func publishInterruptBoundary(
                surfaceId: String,
                agentKey: String,
                sessionSequences: [String: Int64],
                observedHeadSequence: Int64
            ) {
                let scope = InterruptScope(surfaceId: surfaceId, agentKey: agentKey)
                interruptSnapshots.withLock { snapshot in
                    if sessionSequences.isEmpty {
                        snapshot.boundaries.removeValue(forKey: scope)
                    } else {
                        snapshot.boundaries[scope] = UserInterruptBoundary(
                            sessionSequences: sessionSequences,
                            observedHeadSequence: max(
                                observedHeadSequence,
                                snapshot.boundaries[scope]?.observedHeadSequence ?? 0
                            )
                        )
                    }
                }
            }
            func allInterruptBoundaries(
                observedHeadSequence: Int64
            ) -> [InterruptScope: UserInterruptBoundary] {
                var boundaries: [InterruptScope: UserInterruptBoundary] = [:]
                for (surfaceId, byAgent) in state.sessions {
                    for agentKey in byAgent.keys {
                        let sessionSequences = state.userInterruptSessionBoundary(
                            surfaceId: surfaceId,
                            agentKey: agentKey
                        )
                        if !sessionSequences.isEmpty {
                            boundaries[InterruptScope(surfaceId: surfaceId, agentKey: agentKey)] =
                                UserInterruptBoundary(
                                    sessionSequences: sessionSequences,
                                    observedHeadSequence: observedHeadSequence
                                )
                        }
                    }
                }
                return boundaries
            }
            // Loaded once from the store, then maintained in memory as
            // restore records new aliases: canonicalizing a replay fold via
            // per-event SQL lookups would cost two round-trips per event.
            var aliases: AgentJournalAliasResolver?
            func resolver(_ store: AgentJournalStore) -> AgentJournalAliasResolver? {
                if let aliases { return aliases }
                do {
                    let maps = try store.aliasMaps()
                    let loaded = AgentJournalAliasResolver(
                        workspaces: maps.workspaces,
                        surfaces: maps.surfaces
                    )
                    aliases = loaded
                    return loaded
                } catch {
                    // Fail closed: without alias state, canonicalization
                    // could attach lifecycle to a stale identity. Drop the
                    // operation with a diagnostic and retry on the next one.
                    CmuxEventBus.shared.publish(
                        name: "agent.journal.aliases_unavailable",
                        category: "agent",
                        source: "journal"
                    )
#if DEBUG
                    cmuxDebugLog("agentJournal.aliases.loadError \(String(describing: error))")
#endif
                    return nil
                }
            }
            func reconcile(_ event: AgentJournalEvent, store: AgentJournalStore, deliver: Bool) async -> Bool {
                guard let eventAliases = resolver(store) else { return false }
                // The consumer is serial: after aliases resolve, this event's
                // lifecycle/notification fold completes before another
                // operation can inspect the reconciliation cursor.
                noteReconciledSequence(event.sequence)
                reconciliationCursorDidAdvance(event)
                let canonical = Self.canonicalized(event, aliases: eventAliases)
                let decision = notifications.apply(canonical)
                var snapshotEvent = canonical
                var application: LifecycleApplication?
                if decision.disposition != .stale, decision.projectsLifecycle {
                    let lifecycleEvent = notifications.lifecycleEvent(canonical)
                    snapshotEvent = lifecycleEvent
                    application = Self.reduceIngest(
                        lifecycleEvent,
                        sourceKind: canonical.kind,
                        aliases: eventAliases,
                        reducer: reducer,
                        state: &state
                    )
                }
                let interruptBoundary = snapshotEvent.draft.surfaceId.map { surfaceId in
                    (
                        surfaceId: surfaceId,
                        agentKey: snapshotEvent.agentKey,
                        sessionSequences: state.userInterruptSessionBoundary(
                            surfaceId: surfaceId,
                            agentKey: snapshotEvent.agentKey
                        ),
                        observedHeadSequence: event.sequence
                    )
                }
                if let application {
                    await MainActor.run {
                        Self.apply(
                            application.assignment,
                            workspaceHint: application.workspaceHint,
                            activity: application.activity
                        )
                        if let interruptBoundary {
                            publishInterruptBoundary(
                                surfaceId: interruptBoundary.surfaceId,
                                agentKey: interruptBoundary.agentKey,
                                sessionSequences: interruptBoundary.sessionSequences,
                                observedHeadSequence: interruptBoundary.observedHeadSequence
                            )
                        }
                    }
                } else if let interruptBoundary {
                    publishInterruptBoundary(
                        surfaceId: interruptBoundary.surfaceId,
                        agentKey: interruptBoundary.agentKey,
                        sessionSequences: interruptBoundary.sessionSequences,
                        observedHeadSequence: interruptBoundary.observedHeadSequence
                    )
                }
                Self.clearInvalidatedNotifications(canonical, decision: decision)
                let notificationEvent = Self.canonicalized(decision.notificationEvent ?? canonical, aliases: eventAliases)
                guard notificationEvent.draft.attention?.notification != nil else { return false }
                guard let identity = decision.identity else {
                    Self.notificationDiagnostic(canonical.draft, reason: decision.disposition.rawValue)
                    return false
                }
                guard !Task.isCancelled,
                      let delivery = await MainActor.run(body: { Self.notificationAdmission(notificationEvent.draft) }) else { return false }
                guard Self.claimNotification(notificationEvent, decision: decision, store: store) else { return false }
                if deliver {
                    await MainActor.run { Self.deliverNotification(notificationEvent, identity: identity, admission: delivery) }
                }
                return true
            }
            func submit(_ draft: AgentJournalEventDraft, id: UUID?, store: AgentJournalStore) async {
                do {
                    let outcome = try store.append(draft)
                    let event = AgentJournalEvent(sequence: outcome.sequence,
                        committedAtMs: outcome.committedAtMs, draft: draft)
                    // An admission waiter renders its own effect. A fire-and-forget
                    // observation has no waiter, so a completion it releases must be
                    // delivered here or its receipt would be spent for nothing.
                    let accepted = await reconcile(event, store: store, deliver: id == nil)
                    admissions.complete(id, accepted: accepted)
                } catch {
                    Self.notificationDiagnostic(draft, reason: "storage-unavailable")
                    admissions.complete(id, accepted: false)
                }
            }
            func reconcileCommittedRows(
                store: AgentJournalStore
            ) async throws -> Int64 {
                // A successful store scan may cross a pruned sequence prefix
                // or undecodable rows, both of which are safe to cover even
                // though they cannot advance the event-by-event cursor.
                // Capture a durable upper bound once: commits arriving after
                // this scan began belong to the next FIFO operation and cannot
                // keep the sole journal consumer chasing a moving head.
                let upperBound = try store.headSequence()
                var cursor = reconciledThroughSequence
                while cursor < upperBound {
                    let page = try store.readPage(afterSequence: cursor, limit: 2_048)
                    reconciliationPageRead()
                    if page.isEmpty {
                        cursor = upperBound
                        break
                    }
                    for event in page.events where event.sequence <= upperBound
                        && !containsReconciledSequence(event.sequence) {
                        _ = await reconcile(event, store: store, deliver: true)
                    }
                    cursor = max(cursor, min(page.scannedThroughSequence, upperBound))
                }
                noteReconciledScan(through: upperBound)
                let reconciledBoundaries = allInterruptBoundaries(
                    observedHeadSequence: upperBound
                )
                await MainActor.run {
                    interruptSnapshots.withLock { $0.boundaries = reconciledBoundaries }
                }
                return upperBound
            }
            for await operation in channel.stream {
                guard let store = lazyStore.store() else {
                    // Fails closed (no badges), but never silently: the open
                    // failure itself was reported on the event bus, and each
                    // dropped operation is visible in the debug log.
#if DEBUG
                    cmuxDebugLog("agentJournal.op.dropped reason=storeUnavailable")
#endif
                    admissions.complete(operation.admissionID, accepted: false)
                    operation.receipt?.finish()
                    continue
                }
                if let id = operation.admissionID, !admissions.contains(id) { continue }
                switch operation {
                case .ingest(let event):
                    _ = await reconcile(event, store: store, deliver: true)
                case .submit(let draft, let id):
                    await submit(draft, id: id, store: store)
                case .feed(let input, let id):
                    if let draft = input.draft() {
                        await submit(draft, id: id, store: store)
                    } else {
                        admissions.complete(id, accepted: false)
                    }
                case .requestInterrupt(
                    let surfaceId,
                    let workspaceId,
                    let agentKey,
                    let source,
                    let boundary,
                    let receipt
                ):
                    guard !boundary.sessionSequences.isEmpty else {
                        receipt.finish()
                        continue
                    }
                    // The second phase enters at the back of this FIFO so hook
                    // ingress queued around the click is reconciled before the
                    // captured click-time session token is settled.
                    operationContinuation.yield(.settleInterrupt(
                        surfaceId: surfaceId,
                        workspaceId: workspaceId,
                        agentKey: agentKey,
                        source: source,
                        boundary: boundary,
                        receipt: receipt
                    ))
                case .settleInterrupt(
                    let surfaceId,
                    let workspaceId,
                    let agentKey,
                    let source,
                    let boundary,
                    let receipt
                ):
                    defer { receipt.finish() }
                    // The hook worker commits before it enqueues `.ingest`.
                    // Fold every durable row first, then atomically require
                    // only the captured session to be unchanged. Unrelated
                    // pane traffic cannot spin or starve this sole consumer.
                    do {
                        _ = try await reconcileCommittedRows(store: store)
                        let drafts = state.userInterruptDrafts(
                            surfaceId: surfaceId,
                            workspaceId: workspaceId,
                            agentKey: agentKey,
                            source: source,
                            sessionBoundary: boundary.sessionSequences
                        )
                        var sessionAdvancedDuringAppend = false
                        for draft in drafts {
                            let sessionKey = AgentLifecycleReducerState.sessionKey(for: draft)
                            guard boundary.sessionSequences[sessionKey] != nil,
                                  let outcome = try store.append(
                                      draft,
                                      ifSessionHasNoEventAfter: boundary.observedHeadSequence
                                  ) else {
                                sessionAdvancedDuringAppend = true
                                continue
                            }
                            _ = await reconcile(
                                AgentJournalEvent(
                                    sequence: outcome.sequence,
                                    committedAtMs: outcome.committedAtMs,
                                    draft: draft
                                ),
                                store: store,
                                deliver: true
                            )
                        }
                        if sessionAdvancedDuringAppend {
                            _ = try await reconcileCommittedRows(store: store)
                        }
                    } catch {
                        CmuxEventBus.shared.publish(
                            name: "agent.journal.append_failed",
                            category: "agent",
                            source: "journal",
                            payload: ["kind": AgentJournalEventKind.turnCompleted.rawValue]
                        )
#if DEBUG
                        cmuxDebugLog("agentJournal.interrupt.error \(String(describing: error))")
#endif
                    }
                case .append(let draft):
                    do {
                        let outcome = try store.append(draft)
                        operationContinuation.yield(
                            .ingest(
                                AgentJournalEvent(
                                    sequence: outcome.sequence,
                                    committedAtMs: outcome.committedAtMs,
                                    draft: draft
                                )
                            )
                        )
                    } catch {
                        CmuxEventBus.shared.publish(
                            name: "agent.journal.append_failed",
                            category: "agent",
                            source: "journal",
                            payload: ["kind": draft.kind.rawValue]
                        )
#if DEBUG
                        cmuxDebugLog("agentJournal.append.error \(String(describing: error))")
#endif
                    }
                case .recordAliases(let workspaces, let surfaces):
                    do {
                        defer { aliases?.merge(workspaces: workspaces, surfaces: surfaces) }
                        try store.recordRestoreAliases(
                            workspaceAliases: workspaces,
                            surfaceAliases: surfaces
                        )
#if DEBUG
                        cmuxDebugLog(
                            "agentJournal.aliases.recorded surfaces=\(surfaces.count) " +
                                "workspaces=\(workspaces.count)"
                        )
#endif
                    } catch {
                        // In-memory state above keeps the live run correct;
                        // the persistence gap (replay after relaunch) is
                        // recorded in release builds too.
                        CmuxEventBus.shared.publish(
                            name: "agent.journal.alias_persist_failed",
                            category: "agent",
                            source: "journal",
                            payload: ["surfaces": surfaces.count, "workspaces": workspaces.count]
                        )
#if DEBUG
                        cmuxDebugLog("agentJournal.aliases.error \(String(describing: error))")
#endif
                    }
                case .startupReplay:
                    guard let replayAliases = resolver(store) else { continue }
                    guard let replay = Self.reduceStartupReplay(
                        store: store,
                        aliases: replayAliases,
                        reducer: reducer,
                        replayPolicy: replayPolicy,
                        state: &state,
                        notifications: &notifications
                    ) else { continue }
                    noteReconciledScan(through: replay.scannedThroughSequence)
                    let replayBoundaries = allInterruptBoundaries(
                        observedHeadSequence: replay.scannedThroughSequence
                    )
                    await MainActor.run {
                        for assignment in replay.assignments {
                            Self.apply(assignment, workspaceHint: nil)
                        }
                        interruptSnapshots.withLock { $0.boundaries = replayBoundaries }
                    }
                }
            }
        }
    }

    deinit {
        admissions.finish()
        consumerTask?.cancel()
        operations?.finish()
        lazyStore?.close()
    }

    /// Whether the journal is configured (a database URL resolved). The
    /// store itself opens lazily off-main on first append/consume; this
    /// check never opens it, so it is safe from any context.
    var isAvailable: Bool { lazyStore != nil }

    /// Full body of the `agent_journal_append` socket verb: decode, commit
    /// durably, enqueue reduction, and reply with the committed sequence.
    ///
    /// Runs on the socket worker thread; the reply IS the emitting hook's
    /// durable acknowledgement, so the SQLite commit happens inline here.
    func handleAppendCommand(_ args: String) -> String {
        guard let store = lazyStore?.store(), let operations else {
            return "ERROR: agent journal unavailable"
        }
        let payload = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else {
            return "ERROR: Usage: agent_journal_append <event-json>"
        }
        let draft: AgentJournalEventDraft
        do {
            draft = try JSONDecoder().decode(AgentJournalEventDraft.self, from: data)
        } catch {
            // Stable product-level reply; implementation detail stays in the
            // debug log (the caller's dead-letter keeps the draft itself).
#if DEBUG
            cmuxDebugLog("agentJournal.append.invalid \(String(describing: error))")
#endif
            return "ERROR: invalid agent journal event"
        }
        do {
            let outcome = try store.append(draft)
            operations.yield(
                .ingest(
                    AgentJournalEvent(
                        sequence: outcome.sequence,
                        committedAtMs: outcome.committedAtMs,
                        draft: draft
                    )
                )
            )
#if DEBUG
            cmuxDebugLog(
                "agentJournal.append kind=\(draft.kind.rawValue) agent=\(draft.agentKey) " +
                    "seq=\(outcome.sequence) replayed=\(outcome.replayed ? 1 : 0) " +
                    "attributed=\(draft.unattributedReason == nil ? 1 : 0)"
            )
#endif
            return outcome.replayed ? "OK \(outcome.sequence) replayed" : "OK \(outcome.sequence)"
        } catch {
            CmuxEventBus.shared.publish(
                name: "agent.journal.append_failed",
                category: "agent",
                source: "journal",
                payload: ["kind": draft.kind.rawValue]
            )
#if DEBUG
            cmuxDebugLog("agentJournal.append.error \(String(describing: error))")
#endif
            return "ERROR: agent journal append failed"
        }
    }

    /// Queues a diagnostic event for the owned journal consumer without
    /// blocking the caller on SQLite I/O.
    func enqueueAppend(_ draft: AgentJournalEventDraft) {
        operations?.yield(.append(draft))
    }

    /// Journals a user interrupt for every session of `agentKey` the journal
    /// has running on the surface (see ``AgentJournalEventDraft/userInterrupt``).
    ///
    /// - Returns: A receipt that completes after committed hook rows and any
    ///   derived interrupt events have been reconciled.
    @discardableResult
    func recordUserInterrupt(
        surfaceId: UUID,
        workspaceId: UUID,
        agentKey: String,
        source: String,
        boundary: UserInterruptBoundary
    ) -> AgentJournalOperationReceipt {
        let receipt = AgentJournalOperationReceipt()
        guard let operations else {
            receipt.finish()
            return receipt
        }
        operations.yield(.requestInterrupt(
            surfaceId: surfaceId.uuidString,
            workspaceId: workspaceId.uuidString,
            agentKey: agentKey,
            source: source,
            boundary: boundary,
            receipt: receipt
        ))
        return receipt
    }

    /// Captures the exact running session generations and observed journal head
    /// visible at a Stop click. This is a memory-only lock read; it never opens
    /// or queries SQLite on the main actor.
    func captureUserInterruptSessionBoundary(
        surfaceId: UUID,
        agentKey: String
    ) -> UserInterruptBoundary {
        let scope = InterruptScope(surfaceId: surfaceId.uuidString, agentKey: agentKey)
        return interruptSnapshots.withLock {
            $0.boundaries[scope] ?? UserInterruptBoundary(
                sessionSequences: [:],
                observedHeadSequence: 0
            )
        }
    }

    /// Records the workspace/panel identity remaps produced by one restored
    /// workspace, so journaled history re-attaches to the restored panels.
    func noteRestoredIdentityAliases(
        oldWorkspaceId: UUID?,
        newWorkspaceId: UUID,
        oldToNewPanelIds: [UUID: UUID]
    ) {
        guard let operations else { return }
        var workspaces: [String: String] = [:]
        if let oldWorkspaceId, oldWorkspaceId != newWorkspaceId {
            workspaces[oldWorkspaceId.uuidString] = newWorkspaceId.uuidString
        }
        var surfaces: [String: String] = [:]
        for (old, new) in oldToNewPanelIds where old != new {
            surfaces[old.uuidString] = new.uuidString
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.aliases.note workspace=\(newWorkspaceId.uuidString.prefix(8)) " +
                "pairs=\(oldToNewPanelIds.count) remapped=\(surfaces.count) " +
                "workspaceRemapped=\(workspaces.count)"
        )
#endif
        guard !workspaces.isEmpty || !surfaces.isEmpty else { return }
        operations.yield(.recordAliases(workspaces: workspaces, surfaces: surfaces))
    }

    /// Requests a replay of the journal into sidebar lifecycle state. Called
    /// once session restore has settled (aliases recorded); idempotent — the
    /// fold deduplicates by sequence, and only replay-safe phases repaint.
    func noteStartupReplayReady() {
        operations?.yield(.startupReplay)
    }

    /// Enqueues lifecycle observations without blocking the main actor or creating a hook process.
    func observe(_ draft: AgentJournalEventDraft) {
        operations?.yield(.submit(draft, nil))
    }

    /// Uses the same durable semantic gate for actionable Feed delivery.
    func admitNotification(_ draft: AgentJournalEventDraft) async -> Bool {
        await admit { .submit(draft, $0) }
    }

    func observeFeed(_ input: AgentFeedSemanticInput) {
        operations?.yield(.feed(input, nil))
    }

    func admitFeedNotification(_ input: AgentFeedSemanticInput) async -> Bool {
        await admit { .feed(input, $0) }
    }

    private func admit(_ operation: (UUID) -> Operation) async -> Bool {
        guard let operations else { return false }
        let id = UUID()
        let admissions = self.admissions
        defer { admissions.forget(id) }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard admissions.register(id, continuation: continuation) else { return }
                if case .terminated = operations.yield(operation(id)) {
                    admissions.complete(id, accepted: false)
                }
            }
        }, onCancel: {
            admissions.cancel(id)
        })
    }
}
