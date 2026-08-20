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
            for await operation in stream {
                guard let store = lazyStore.store() else { continue }
                switch operation {
                case .ingest(let event):
                    if let application = Self.reduceIngest(
                        event,
                        store: store,
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
                    try? store.recordRestoreAliases(
                        workspaceAliases: workspaces,
                        surfaceAliases: surfaces
                    )
                case .startupReplay:
                    let assignments = Self.reduceStartupReplay(
                        store: store,
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

    /// Whether the journal is usable (opens it if this is the first access;
    /// callers must be off-main).
    var isAvailable: Bool { lazyStore?.store() != nil }

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
            return "ERROR: invalid agent journal event: \(error.localizedDescription)"
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
            return "ERROR: agent journal append failed: \(String(describing: error))"
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
        store: AgentJournalStore,
        reducer: AgentLifecycleReducer,
        state: inout AgentLifecycleReducerState
    ) -> LifecycleApplication? {
        let canonical = canonicalized(event, store: store)
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
        reducer: AgentLifecycleReducer,
        replayPolicy: AgentJournalReplayPolicy,
        state: inout AgentLifecycleReducerState
    ) -> [AgentLifecycleAssignment] {
        var cursor: Int64 = 0
        var folded = 0
        while true {
            guard let page = try? store.events(afterSequence: cursor, limit: 2_048),
                  !page.isEmpty else {
                break
            }
            for event in page {
                reducer.apply(canonicalized(event, store: store), to: &state)
            }
            folded += page.count
            cursor = page[page.count - 1].sequence
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
            "agentJournal.replay folded=\(folded) painted=\(assignments.count) " +
                "unattributed=\(state.unattributedEvents.count)"
        )
#endif
        return assignments
    }

    /// Rewrites the event's identity through the restore alias chains so
    /// sessions that span an app relaunch reduce under one canonical surface.
    private static func canonicalized(
        _ event: AgentJournalEvent,
        store: AgentJournalStore
    ) -> AgentJournalEvent {
        var draft = event.draft
        if let surfaceId = draft.surfaceId,
           let resolved = try? store.resolvedSurfaceId(surfaceId) {
            draft.surfaceId = resolved
        }
        if let workspaceId = draft.workspaceId,
           let resolved = try? store.resolvedWorkspaceId(workspaceId) {
            draft.workspaceId = resolved
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

    /// Projects the journal phase onto the sidebar's lifecycle enum. The
    /// sidebar has no dedicated error rendering yet, so `error` uses the
    /// needs-input treatment (matching the pre-journal pipeline) while the
    /// journal retains the honest phase.
    private static func lifecycle(for phase: AgentLifecyclePhase) -> AgentHibernationLifecycleState {
        switch phase {
        case .unknown: .unknown
        case .running: .running
        case .needsInput: .needsInput
        case .idle: .idle
        case .error: .needsInput
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
