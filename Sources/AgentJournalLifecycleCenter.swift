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
        case submit(AgentJournalEventDraft, CheckedContinuation<Bool, Never>?)
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
            var notifications = AgentNotificationReconciler()
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
                let canonical = Self.canonicalized(event, aliases: eventAliases)
                let decision = notifications.apply(canonical)
                if decision.disposition != .stale,
                   let application = Self.reduceIngest(canonical, aliases: eventAliases,
                       reducer: reducer, state: &state) {
                    await MainActor.run { Self.apply(application.assignment, workspaceHint: application.workspaceHint) }
                }
                Self.clearInvalidatedNotifications(canonical, decision: decision)
                guard canonical.draft.attention?.notification != nil else { return false }
                guard let identity = decision.identity else {
                    Self.notificationDiagnostic(canonical.draft, reason: decision.disposition.rawValue)
                    return false
                }
                if deliver, !(await MainActor.run(body: { Self.notificationTargetIsCurrent(canonical.draft) })) {
                    return false
                }
                guard Self.claimNotification(canonical, decision: decision, store: store) else { return false }
                if deliver {
                    await MainActor.run { Self.deliverNotification(canonical, identity: identity) }
                }
                return true
            }
            for await operation in stream {
                guard let store = lazyStore.store() else {
                    // Fails closed (no badges), but never silently: the open
                    // failure itself was reported on the event bus, and each
                    // dropped operation is visible in the debug log.
#if DEBUG
                    cmuxDebugLog("agentJournal.op.dropped reason=storeUnavailable")
#endif
                    if case .submit(_, let continuation) = operation { continuation?.resume(returning: false) }
                    continue
                }
                switch operation {
                case .ingest(let event):
                    _ = await reconcile(event, store: store, deliver: true)
                case .submit(let draft, let continuation):
                    do {
                        let outcome = try store.append(draft)
                        let event = AgentJournalEvent(sequence: outcome.sequence,
                            committedAtMs: outcome.committedAtMs, draft: draft)
                        let accepted = await reconcile(event, store: store, deliver: false)
                        continuation?.resume(returning: accepted)
                    } catch {
                        Self.notificationDiagnostic(draft, reason: "storage-unavailable")
                        continuation?.resume(returning: false)
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
                        state: &state,
                        notifications: &notifications
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

    /// Enqueues lifecycle observations without blocking the main actor or creating a hook process.
    func observe(_ draft: AgentJournalEventDraft) {
        operations?.yield(.submit(draft, nil))
    }

    /// Uses the same durable semantic gate for actionable Feed delivery.
    func admitNotification(_ draft: AgentJournalEventDraft) async -> Bool {
        guard let operations else { return false }
        return await withCheckedContinuation { continuation in
            operations.yield(.submit(draft, continuation))
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
