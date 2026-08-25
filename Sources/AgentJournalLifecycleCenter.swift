import CmuxAgentJournal
import Foundation

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
/// assignment. The store itself is opened lazily off-main (see
/// ``AgentJournalLazyStore``), so main-actor callers only ever enqueue.
final class AgentJournalLifecycleCenter: Sendable {
    static let shared = AgentJournalLifecycleCenter()

    private enum Operation: Sendable {
        case ingest(AgentJournalEvent)
        case recordAliases(workspaces: [String: String], surfaces: [String: String])
        case startupReplay
    }

    private let lazyStore: AgentJournalLazyStore?
    private let operations: AsyncStream<Operation>.Continuation?
    private let consumerTask: Task<Void, Never>?

    convenience init() {
        self.init(databaseURL: Self.defaultDatabaseURL())
    }

    init(databaseURL: URL?) {
        guard let databaseURL else {
            self.lazyStore = nil
            self.operations = nil
            self.consumerTask = nil
            return
        }
        let lazyStore = AgentJournalLazyStore(databaseURL: databaseURL)
        self.lazyStore = lazyStore
        var continuation: AsyncStream<Operation>.Continuation?
        let stream = AsyncStream<Operation>(bufferingPolicy: .unbounded) { continuation = $0 }
        self.operations = continuation
        self.consumerTask = Task.detached(priority: .utility) {
            let reducer = AgentLifecycleReducer()
            let replayPolicy = AgentJournalReplayPolicy()
            var state = AgentLifecycleReducerState()
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
            for await operation in stream {
                guard let store = lazyStore.store() else {
                    // Fails closed (no badges), but never silently: the open
                    // failure itself was reported on the event bus, and each
                    // dropped operation is visible in the debug log.
#if DEBUG
                    cmuxDebugLog("agentJournal.op.dropped reason=storeUnavailable")
#endif
                    continue
                }
                switch operation {
                case .ingest(let event):
                    guard let eventAliases = resolver(store) else { continue }
                    if let application = Self.reduceIngest(
                        event,
                        aliases: eventAliases,
                        reducer: reducer,
                        state: &state
                    ) {
                        // Await the application so assignments reach the
                        // sidebar in journal-consumer order.
                        await MainActor.run {
                            Self.apply(application.assignment, workspaceHint: application.workspaceHint)
                        }
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
                    let assignments = Self.reduceStartupReplay(
                        store: store,
                        aliases: replayAliases,
                        reducer: reducer,
                        replayPolicy: replayPolicy,
                        state: &state
                    )
                    if !assignments.isEmpty {
                        await MainActor.run {
                            for assignment in assignments {
                                Self.apply(assignment, workspaceHint: nil)
                            }
                        }
                    }
                }
            }
        }
    }

    deinit {
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

    // MARK: - Consumer

    private struct LifecycleApplication: Sendable {
        let assignment: AgentLifecycleAssignment
        let workspaceHint: String?
    }

    private static func reduceIngest(
        _ event: AgentJournalEvent,
        aliases: AgentJournalAliasResolver,
        reducer: AgentLifecycleReducer,
        state: inout AgentLifecycleReducerState
    ) -> LifecycleApplication? {
        let canonical = canonicalized(event, aliases: aliases)
        reducer.apply(canonical, to: &state)
        guard canonical.draft.unattributedReason == nil else {
            publishUnattributedDiagnostic(canonical)
            return nil
        }
        guard let surfaceId = canonical.draft.surfaceId else {
            publishUnattributedDiagnostic(canonical)
            return nil
        }
        guard !canonical.draft.isSubagent else { return nil }
        return LifecycleApplication(
            assignment: AgentLifecycleAssignment(
                surfaceId: surfaceId,
                agentKey: canonical.agentKey,
                phase: state.combinedPhase(surfaceId: surfaceId, agentKey: canonical.agentKey)
            ),
            workspaceHint: canonical.draft.workspaceId
        )
    }

    private static func reduceStartupReplay(
        store: AgentJournalStore,
        aliases: AgentJournalAliasResolver,
        reducer: AgentLifecycleReducer,
        replayPolicy: AgentJournalReplayPolicy,
        state: inout AgentLifecycleReducerState
    ) -> [AgentLifecycleAssignment] {
        var cursor: Int64 = 0
        var folded = 0
        var skipped = 0
        while true {
            let page: AgentJournalReadPage
            do {
                page = try store.readPage(afterSequence: cursor, limit: 2_048)
            } catch {
                // An incomplete fold must not paint partial replay state:
                // record the failure and paint nothing (live events still
                // reduce and self-correct per session).
                CmuxEventBus.shared.publish(
                    name: "agent.journal.replay_failed",
                    category: "agent",
                    source: "journal",
                    payload: ["cursor": cursor, "folded": folded]
                )
#if DEBUG
                cmuxDebugLog("agentJournal.replay.error cursor=\(cursor) \(String(describing: error))")
#endif
                return []
            }
            if page.isEmpty { break }
            for event in page.events {
                reducer.apply(canonicalized(event, aliases: aliases), to: &state)
            }
            folded += page.events.count
            skipped += page.skippedSequences.count
            // Advance over undecodable rows too so a foreign-schema run can
            // never stall the fold or hide the events behind it.
            cursor = page.scannedThroughSequence
        }
        let startup = replayPolicy.startupSnapshot(from: state.snapshot())
        var assignments: [AgentLifecycleAssignment] = []
        for (surfaceId, byAgent) in startup.phases {
            for (agentKey, phase) in byAgent {
                assignments.append(
                    AgentLifecycleAssignment(surfaceId: surfaceId, agentKey: agentKey, phase: phase)
                )
            }
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.replay folded=\(folded) skipped=\(skipped) " +
                "painted=\(assignments.count) unattributed=\(state.unattributedEvents.count)"
        )
#endif
        return assignments
    }

    /// Rewrites the event's identity through the restore alias chains so
    /// sessions that span an app relaunch reduce under one canonical surface.
    private static func canonicalized(
        _ event: AgentJournalEvent,
        aliases: AgentJournalAliasResolver
    ) -> AgentJournalEvent {
        var draft = event.draft
        // A nil resolution means the alias chain hit its cycle cap (corrupt
        // alias state): the current identity is unknowable, so fail closed —
        // strip the target and keep the event as an explicit diagnostic
        // instead of applying state under a possibly stale identity.
        var cycled = false
        if let surfaceId = draft.surfaceId {
            if let resolved = aliases.resolvedSurfaceId(surfaceId) {
                draft.surfaceId = resolved
            } else {
                cycled = true
            }
        }
        if let workspaceId = draft.workspaceId {
            if let resolved = aliases.resolvedWorkspaceId(workspaceId) {
                draft.workspaceId = resolved
            } else {
                cycled = true
            }
        }
        if cycled {
            draft.workspaceId = nil
            draft.surfaceId = nil
            draft.unattributedReason = "alias-cycle"
        }
        return AgentJournalEvent(
            sequence: event.sequence,
            committedAtMs: event.committedAtMs,
            draft: draft
        )
    }

    private static func publishUnattributedDiagnostic(_ event: AgentJournalEvent) {
        CmuxEventBus.shared.publish(
            name: "agent.journal.unattributed",
            category: "agent",
            source: "journal",
            payload: [
                "sequence": event.sequence,
                "kind": event.kind.rawValue,
                "agent": event.draft.source,
                "agent_key": event.agentKey,
                "native_event": event.draft.nativeEvent ?? "",
                "reason": event.draft.unattributedReason ?? "missing-surface",
            ]
        )
#if DEBUG
        cmuxDebugLog(
            "agentJournal.unattributed seq=\(event.sequence) kind=\(event.kind.rawValue) " +
                "agent=\(event.draft.source) reason=\(event.draft.unattributedReason ?? "missing-surface")"
        )
#endif
    }

    @MainActor
    private static func apply(_ assignment: AgentLifecycleAssignment, workspaceHint: String?) {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(assignment.agentKey) else { return }
        guard let panelId = UUID(uuidString: assignment.surfaceId) else { return }
        let owner: ControlSidebarPanelOwner?
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(panelId) }) {
            owner = .dock(dock)
        } else if let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: workspaceHint.flatMap(UUID.init(uuidString:))
        ) {
            owner = .workspace(located.workspace)
        } else {
            owner = nil
        }
        guard let owner else {
            // Fail closed and record it in release builds too: the panel no
            // longer exists, so the assignment is dropped, never re-homed.
            CmuxEventBus.shared.publish(
                name: "agent.journal.apply_skipped",
                category: "agent",
                source: "journal",
                surfaceId: assignment.surfaceId,
                payload: ["agent_key": assignment.agentKey, "reason": "panelGone"]
            )
#if DEBUG
            cmuxDebugLog(
                "agentJournal.apply.skip surface=\(assignment.surfaceId.prefix(8)) " +
                    "key=\(assignment.agentKey) reason=panelGone"
            )
#endif
            return
        }
        if let phase = assignment.phase {
            owner.setAgentLifecycle(
                key: assignment.agentKey,
                panelId: panelId,
                lifecycle: Self.lifecycle(for: phase)
            )
        } else {
            owner.clearAgentLifecycle(key: assignment.agentKey, panelId: panelId)
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.apply surface=\(assignment.surfaceId.prefix(8)) " +
                "key=\(assignment.agentKey) phase=\(assignment.phase?.rawValue ?? "clear")"
        )
#endif
    }

    /// Projects the journal phase onto the sidebar's lifecycle enum.
    ///
    /// `error` used to borrow the needs-input treatment because nothing
    /// rendered errors distinctly. That is no longer true: `AgentStatus.error`
    /// carries its own red, and the pane border and custom sidebars both render
    /// it, so collapsing the phase here would repaint every errored or
    /// quota-exhausted agent as merely waiting on an answer — the one thing that
    /// state is meant to be distinguishable from.
    static func lifecycle(for phase: AgentLifecyclePhase) -> AgentHibernationLifecycleState {
        switch phase {
        case .unknown: .unknown
        case .running: .running
        case .needsInput: .needsInput
        case .idle: .idle
        case .error: .error
        }
    }

    private static func defaultDatabaseURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CMUX_AGENT_JOURNAL_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard !isRunningUnderAutomatedTests else { return nil }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleID = bundleID?.isEmpty == false ? bundleID! : "com.cmuxterm.app"
        let safeBundleID = resolvedBundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-journal-\(safeBundleID).sqlite3", isDirectory: false)
    }
}
