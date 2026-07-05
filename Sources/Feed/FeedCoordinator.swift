import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
@preconcurrency import UserNotifications
import CmuxSettings
import CmuxSidebar

/// App-level coordinator that owns the shared `WorkstreamStore` and
/// mediates between the socket thread (which processes `feed.*` V2
/// commands) and the main-actor store.
///
/// Blocking hook semantics: a hook calls `feed.push` with a `request_id`
/// and `wait_timeout_seconds`. The coordinator creates the `WorkstreamItem`
/// on the store and parks the socket worker on a `DispatchSemaphore` until
/// the user resolves the item via `feed.*.reply` (or the timeout elapses).
/// Hooks then receive the decision inline in the `feed.push` response.
final class FeedCoordinator: @unchecked Sendable {
    static let shared = FeedCoordinator()
    static let storeInstalledNotification = Notification.Name("cmux.feed.storeInstalled")

    // The store runs on the main actor. The coordinator is not isolated,
    // so it hops to main explicitly when touching the store.
    @MainActor private(set) var store: WorkstreamStore!

    /// Pending blocking-hook waiters keyed by request id. The waiter owns
    /// a semaphore plus a slot for the resolved decision; the reply
    /// handler signals the semaphore after filling the slot.
    private let waiterLock = NSLock()
    private var waiters: [String: PendingWaiter] = [:]

    /// One kqueue-backed DispatchSource per distinct agent PID we've
    /// ever seen. The kernel fires `.exit` the instant the process
    /// dies (or immediately if it's already dead). When that fires
    /// we mark every pending item for that PID as `.expired` and
    /// cancel the source. Keyed by PID so the same agent spawning
    /// multiple prompts only installs one watcher.
    @MainActor private var pidWatchers: [Int: DispatchSourceProcess] = [:]
    private let pidWatcherQueue = DispatchQueue(
        label: "cmux.feed.pidWatcher", qos: .utility
    )

    /// In-flight blocking decisions whose needs-input overlay is currently lit,
    /// keyed by ``AttentionTarget``. Each state keeps the workspace object that
    /// was mutated when surfacing attention, so cleanup does not depend on
    /// resolving a live window route after the decision has already ended.
    /// Main-actor isolated: read/written only from the `@MainActor` attention
    /// methods.
    @MainActor private var pendingAttentionStates: [AttentionTarget: AttentionOverlayState] = [:]

    private init() {}

    /// Must be called once at app launch to install the store.
    @MainActor
    func install(store: WorkstreamStore) {
        self.store = store
        NotificationCenter.default.post(name: Self.storeInstalledNotification, object: self)
        // Catch any pending items that were restored from disk whose
        // agent is already gone. After this, live tracking is
        // kqueue-driven — no polling.
        store.expireAbandonedItems()
        for ppid in store.pending.compactMap(\.ppid) {
            armPidWatcher(ppid: ppid)
        }
    }

    /// Installs a one-shot kqueue watcher for `ppid`. The handler
    /// fires the moment the kernel observes process exit (or
    /// immediately if `ppid` is already dead), marks every pending
    /// item for that PID as `.expired`, and cancels the source.
    /// Idempotent: subsequent calls with the same PID no-op.
    @MainActor
    func armPidWatcher(ppid: Int) {
        guard ppid > 0, pidWatchers[ppid] == nil else { return }
        let src = DispatchSource.makeProcessSource(
            identifier: pid_t(ppid),
            eventMask: .exit,
            queue: pidWatcherQueue
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.store?.expireItems(forPpid: ppid)
                self.pidWatchers[ppid]?.cancel()
                self.pidWatchers.removeValue(forKey: ppid)
            }
        }
        pidWatchers[ppid] = src
        src.resume()
    }

    /// Ingests a wire-frame event and, when `waitTimeout` > 0, blocks the
    /// current (non-main) thread until the item is resolved or the
    /// timeout elapses.
    func ingestBlocking(
        event: WorkstreamEvent,
        waitTimeout: TimeInterval
    ) -> IngestBlockingResult {
        // Codex CLI hook `PermissionRequest`s are non-blocking telemetry (Codex
        // owns the allow/deny via its own reviewer), so they short-circuit to
        // the non-blocking path. Codex app-server (Teams) approvals share the
        // same event name + source but are real decisions cmux resolves through
        // a blocking Feed reply, so they are *not* excluded here and fall
        // through to the blocking semaphore path.
        guard let requestId = event.requestId, waitTimeout > 0, Self.isBlockingDecisionEvent(event.hookEventName),
              !event.isCodexHookPermissionTelemetry else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FeedCoordinator.shared.store.ingest(event)
                    if let ppid = event.ppid, ppid > 0 {
                        FeedCoordinator.shared.armPidWatcher(ppid: ppid)
                    }
                }
            }
            return .acknowledged(itemId: nil)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let waiter = PendingWaiter(semaphore: semaphore)

        // Register the waiter before the store sees the event so a very
        // fast reply can't slip through.
        waiterLock.lock()
        waiters[requestId] = waiter
        waiterLock.unlock()

        // Hop to main to actually insert the item + install the
        // kqueue watcher for the agent's PID. The watcher handler
        // caps the pending lifetime to the agent process lifetime
        // — no polling, no leaked cards when the agent is killed.
        let itemIdSlot = UnsafeItemIdSlot()
        let resolvedAttentionTarget = Self.resolveAttentionTarget(event: event)
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                FeedCoordinator.shared.store.ingest(event)
                itemIdSlot.value = FeedCoordinator.shared.store.items.last?.id
                if let ppid = event.ppid, ppid > 0 {
                    FeedCoordinator.shared.armPidWatcher(ppid: ppid)
                }
                // Surface in-app attention (needs-input status + bell +
                // workspace elevation) for the blocking decision. This fires
                // regardless of app focus, unlike the desktop banner below,
                // so the pending decision is visible in the sidebar even
                // while the user is in another workspace of the same window.
                // The target is resolved before entering this main-thread
                // section so hook-session disk I/O never extends the UI
                // critical section.
                // The target is recorded on the waiter here — inside the
                // ingest `main.sync`, before the card can render and a reply
                // can fire — so the overlay is cleared exactly once when the
                // decision concludes (no race with `deliverReply`).
                if let target = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: event,
                    resolved: resolvedAttentionTarget
                ) {
                    FeedCoordinator.shared.waiterLock.lock()
                    FeedCoordinator.shared.waiters[requestId]?.attentionTarget = target
                    FeedCoordinator.shared.waiterLock.unlock()
                }
                #if DEBUG
                FeedCoordinatorTestHooks.afterBlockingEventIngested?(event, requestId)
                #endif
            }
        }

        // If this is a blocking actionable event and the app window isn't
        // focused, post a native notification banner with inline action
        // buttons so the user can respond without switching windows.
        postNotificationIfStillAwaiting(event: event, requestId: requestId)

        let deadline: DispatchTime = .now() + waitTimeout
        let waitResult = semaphore.wait(timeout: deadline)

        waiterLock.lock()
        let w = waiters.removeValue(forKey: requestId)
        waiterLock.unlock()

        switch waitResult {
        case .success:
            if let decision = w?.decision {
                // `deliverReply` concludes the attention overlay on resolve.
                return .resolved(itemId: itemIdSlot.value, decision: decision)
            }
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(w?.attentionTarget)
            expireTimedOutItem(itemIdSlot.value)
            return .timedOut(itemId: itemIdSlot.value)
        case .timedOut:
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(w?.attentionTarget)
            expireTimedOutItem(itemIdSlot.value)
            return .timedOut(itemId: itemIdSlot.value)
        }
    }

    /// Concludes an attention overlay (if any) on the main actor, hopping if
    /// called from the socket worker thread.
    private func concludeAttentionOnMain(_ target: AttentionTarget?) {
        guard let target else { return }
        let conclude: @Sendable () -> Void = { [target] in
            MainActor.assumeIsolated {
                FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
            }
        }
        if Thread.isMainThread {
            conclude()
        } else {
            DispatchQueue.main.async(execute: conclude)
        }
    }

    /// Called by the `feed.*.reply` handlers. Marks the corresponding
    /// item resolved on the main-actor store and wakes any waiter.
    func deliverReply(requestId: String, decision: WorkstreamDecision) {
        waiterLock.lock()
        let attentionTarget = waiters[requestId]?.attentionTarget
        if let waiter = waiters[requestId] {
            waiter.decision = decision
            waiter.semaphore.signal()
        }
        waiterLock.unlock()

        // The user decided: conclude the needs-input overlay so the agent's
        // running/idle state shows through (refcounted so an overlapping
        // decision on the same panel keeps it lit until it too concludes).
        concludeAttentionOnMain(attentionTarget)

        let resolve: @Sendable () -> Void = { [requestId, decision] in
            MainActor.assumeIsolated {
                let store = FeedCoordinator.shared.store
                guard let store else { return }
                if let itemId = Self.findItemId(for: requestId, in: store.items) {
                    store.markResolved(itemId, decision: decision)
                }
            }
        }
        if Thread.isMainThread {
            resolve()
        } else {
            DispatchQueue.main.async(execute: resolve)
        }

        cancelNotification(requestId: requestId)
    }

    fileprivate func isAwaitingDecision(requestId: String) -> Bool {
        waiterLock.lock()
        defer { waiterLock.unlock() }
        guard let waiter = waiters[requestId] else { return false }
        return waiter.decision == nil
    }

    private static func findItemId(
        for requestId: String,
        in items: [WorkstreamItem]
    ) -> UUID? {
        for item in items.reversed() {
            switch item.payload {
            case .permissionRequest(let rid, _, _, _) where rid == requestId:
                return item.id
            case .exitPlan(let rid, _, _) where rid == requestId:
                return item.id
            case .question(let rid, _) where rid == requestId:
                return item.id
            default:
                continue
            }
        }
        return nil
    }

    private func expireTimedOutItem(_ itemId: UUID?) {
        guard let itemId else { return }
        let expire: @Sendable () -> Void = { [itemId] in
            MainActor.assumeIsolated {
                FeedCoordinator.shared.store?.markExpired(itemId)
            }
        }
        if Thread.isMainThread {
            expire()
        } else {
            DispatchQueue.main.sync(execute: expire)
        }
    }

    enum IngestBlockingResult {
        case acknowledged(itemId: UUID?)
        case resolved(itemId: UUID?, decision: WorkstreamDecision)
        case timedOut(itemId: UUID?)
    }
}

// MARK: - In-app attention surfacing

extension FeedCoordinator {
    /// The blocking-decision hook events that warrant pulling the user's
    /// attention to the owning workspace: a tool permission, a plan
    /// approval, or a question. Keeping this as one predicate (rather than
    /// branching per event at each call site) is what makes the attention
    /// surface uniform across every event type and agent routed through
    /// `feed.push` — a new blocking event type only has to be added here.
    static func isBlockingDecisionEvent(_ hookEventName: WorkstreamEvent.HookEventName) -> Bool {
        switch hookEventName {
        case .permissionRequest, .exitPlanMode, .askUserQuestion:
            return true
        default:
            return false
        }
    }

    /// Maps a feed `source` (agent id) to the agent-lifecycle status key the
    /// sidebar reads. Claude reports under `claude_code`; every other agent
    /// keys its status by its own source name. Returning the agent's own key
    /// is what lets the existing per-agent resume hooks (e.g. Claude's
    /// `pre-tool-use`) clear the needs-input badge once the agent continues.
    private static let lifecycleStatusKeyOverrides = [
        "claude": "claude_code",
    ]

    static func lifecycleStatusKey(forSource source: String) -> String {
        lifecycleStatusKeyOverrides[source] ?? source
    }

    /// Identifies the sidebar slot an attention overlay lights up. Overlays
    /// are refcounted by this key so overlapping blocking decisions on the
    /// same agent/panel don't clear each other's needs-input badge.
    struct AttentionTarget: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID?
        let statusKey: String
    }

    /// The localized "Needs input" sidebar status the overlay sets. Exposed so
    /// ``concludeBlockingDecisionAttention(_:)`` can confirm it's still the
    /// value we wrote before clearing it (rather than one an agent hook
    /// replaced in the meantime).
    static var needsInputStatusValue: String {
        String(localized: "feed.status.needsInput", defaultValue: "Needs input")
    }

    /// Surfaces in-app attention for a blocking feed decision: flips the
    /// owning workspace's agent lifecycle to `.needsInput`, sets the
    /// "Needs input" sidebar status, elevates the workspace when
    /// *Reorder on Notification* is enabled, and rings the bell.
    ///
    /// This is the convergence point the PreToolUse→PermissionRequest
    /// migration left behind: the `feed.push` bridge ingested the card and
    /// (when inactive) posted a banner, but never drove the same in-app
    /// attention path the `cmux hooks <agent> notification` hook uses. Doing
    /// it here — once, for every blocking decision — keeps a new event type
    /// from silently swallowing.
    ///
    /// The overlay is cleared by ``concludeBlockingDecisionAttention(_:)``
    /// when the decision resolves or times out. Clearing is refcounted per
    /// ``AttentionTarget`` so overlapping decisions on the same panel keep the
    /// badge lit until the last one concludes.
    ///
    /// - Parameter resolved: the target resolved off the main actor before UI
    ///   mutation, since hook-session lookup may read from disk.
    /// - Returns: the target to conclude once the decision ends, or `nil` if
    ///   nothing was surfaced (no resolvable workspace).
    @MainActor
    func surfaceBlockingDecisionAttention(
        event: WorkstreamEvent,
        resolved: (workspaceId: UUID, surfaceId: UUID?)?
    ) -> AttentionTarget? {
        guard Self.isBlockingDecisionEvent(event.hookEventName) else { return nil }

        #if DEBUG
        if let observer = FeedCoordinatorTestHooks.attentionSurfaceObserver {
            observer(event)
            return nil
        }
        #endif

        guard let resolved else {
            #if DEBUG
            cmuxDebugLog(
                "feed.attention.skip reason=unresolved-target session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) workspace=\(event.workspaceId ?? "nil") receivedAt=\(event.receivedAt.timeIntervalSince1970)"
            )
            #endif
            return nil
        }

        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: resolved.workspaceId),
              let tab = tabManager.tabs.first(where: { $0.id == resolved.workspaceId })
        else {
            #if DEBUG
            cmuxDebugLog(
                "feed.attention.skip reason=missing-workspace session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) workspace=\(resolved.workspaceId.uuidString) receivedAt=\(event.receivedAt.timeIntervalSince1970)"
            )
            #endif
            return nil
        }

        let panelId = Self.resolvePanelId(surfaceId: resolved.surfaceId, tab: tab) ?? tab.focusedPanelId
        let statusKey = Self.lifecycleStatusKey(forSource: event.source)
        let target = AttentionTarget(
            workspaceId: resolved.workspaceId,
            panelId: panelId,
            statusKey: statusKey
        )
        let attentionState = pendingAttentionStates[target] ?? AttentionOverlayState(workspace: tab)
        attentionState.workspace = tab
        attentionState.count += 1
        pendingAttentionStates[target] = attentionState

        // Needs-input lifecycle drives the sidebar badge + hibernation state.
        tab.setAgentLifecycle(key: statusKey, panelId: panelId, lifecycle: .needsInput)
        tab.statusEntries[statusKey] = SidebarStatusEntry(
            key: statusKey,
            value: Self.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF",
            timestamp: Date()
        )

        // Elevate the workspace so it floats to the top of the sidebar,
        // honoring the user's Reorder on Notification preference.
        if UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) {
            tabManager.moveTabToTopForNotification(resolved.workspaceId)
        }

        // Ring the bell (dock bounce while the app is in the background).
        NSApp.requestUserAttention(.informationalRequest)

        return target
    }

    /// Concludes a blocking decision's attention overlay. Decrements the
    /// per-target refcount and, when it reaches zero, clears the needs-input
    /// overlay — but only the parts the feed still owns: the lifecycle is set
    /// to `.running` only if it's still `.needsInput`, and the status entry is
    /// removed only if it still holds our "Needs input" value. Anything an
    /// agent hook replaced in the meantime is left untouched, so a real
    /// running/idle/needs-input update from the agent always wins.
    @MainActor
    func concludeBlockingDecisionAttention(_ target: AttentionTarget) {
        guard let attentionState = pendingAttentionStates[target] else { return }
        if attentionState.count > 1 {
            attentionState.count -= 1
            return
        }
        pendingAttentionStates.removeValue(forKey: target)
        let tab = attentionState.workspace

        // Lifecycle is per-panel, so clearing this panel's needs-input is
        // safe even if another panel still needs input.
        if let panelId = target.panelId,
           tab.agentLifecycleStatesByPanelId[panelId]?[target.statusKey] == .needsInput {
            tab.setAgentLifecycle(key: target.statusKey, panelId: panelId, lifecycle: .running)
        }

        // The status entry is workspace-level (keyed only by statusKey), so it
        // is shared across panels running the same agent. Only remove it once
        // no other panel in this workspace still has a pending decision under
        // the same key — otherwise concluding one panel would wipe another
        // panel's active "Needs input" badge.
        let anotherPanelStillPending = pendingAttentionStates.keys.contains {
            $0.workspaceId == target.workspaceId && $0.statusKey == target.statusKey
        }
        if !anotherPanelStillPending,
           tab.statusEntries[target.statusKey]?.value == Self.needsInputStatusValue {
            tab.statusEntries.removeValue(forKey: target.statusKey)
        }
    }

    /// Resolves the `(workspace, surface)` an attention overlay should target.
    /// The workspace prefers the event's live `workspace_id` (the running
    /// terminal's CMUX_WORKSPACE_ID, a raw UUID) so a stale hook-session map
    /// can't redirect attention to the wrong workspace; it falls back to the
    /// session store when the event omits a parseable id. The surface comes
    /// from the session store only when its workspace matches the resolved
    /// workspace, so a stale entry can't point the panel elsewhere.
    private static func resolveAttentionTarget(
        event: WorkstreamEvent
    ) -> (workspaceId: UUID, surfaceId: UUID?)? {
        let sessionMatch: (workspaceId: UUID, surfaceId: UUID?)? = {
            guard let parsed = FeedJumpResolver.parse(event.sessionId),
                  let resolved = FeedJumpResolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId),
                  let workspaceId = UUID(uuidString: resolved.workspaceId)
            else { return nil }
            return (workspaceId, UUID(uuidString: resolved.surfaceId))
        }()

        let eventWorkspaceId = event.workspaceId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let workspaceId = eventWorkspaceId ?? sessionMatch?.workspaceId else {
            return nil
        }
        // Only trust the session store's surface if it belongs to the
        // workspace we're actually targeting.
        let surfaceId = (sessionMatch?.workspaceId == workspaceId) ? sessionMatch?.surfaceId : nil
        return (workspaceId, surfaceId)
    }

    /// Maps a surface id from the hook-session store to its owning panel id,
    /// tolerating stores that already record the panel id directly.
    @MainActor
    private static func resolvePanelId(surfaceId: UUID?, tab: Workspace) -> UUID? {
        guard let surfaceId else { return nil }
        if tab.panels[surfaceId] != nil { return surfaceId }
        return tab.panelIdFromSurfaceId(TabID(uuid: surfaceId))
    }
}

@MainActor
private final class AttentionOverlayState {
    var count: Int
    var workspace: Workspace

    init(workspace: Workspace) {
        self.count = 0
        self.workspace = workspace
    }
}

private final class PendingWaiter: @unchecked Sendable {
    let semaphore: DispatchSemaphore
    var decision: WorkstreamDecision?
    /// The attention overlay target for this decision, if one was surfaced.
    /// Set inside the ingest `main.sync` (before the card can render and a
    /// reply can fire) and read when the decision concludes, so the
    /// needs-input overlay is cleared exactly once. Guarded by
    /// `FeedCoordinator.waiterLock`.
    var attentionTarget: FeedCoordinator.AttentionTarget?

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }
}

/// Tiny box so the `DispatchQueue.main.sync` closure can mutate an
/// `UUID?` without a capture warning.
private final class UnsafeItemIdSlot: @unchecked Sendable {
    var value: UUID?
}

private final class SnapshotSlot: @unchecked Sendable {
    var value: [WorkstreamItem] = []
}

#if DEBUG
@MainActor
enum FeedCoordinatorTestHooks {
    static var afterBlockingEventIngested: (@Sendable (WorkstreamEvent, String) -> Void)?
    static var isAppActiveOverride: (@Sendable () -> Bool)?
    static var notificationPostObserver: (@Sendable (WorkstreamEvent, String) -> Void)?
    /// Fires when a blocking decision event requests in-app attention
    /// surfacing (needs-input status + bell + elevation). When set, the
    /// production surfacing is short-circuited so tests can assert the
    /// request without a live `TabManager`.
    static var attentionSurfaceObserver: (@Sendable (WorkstreamEvent) -> Void)?
}
#endif

// MARK: - Socket-layer helpers

extension FeedCoordinator {
    /// Thread-safe snapshot of the store's items; hops to main to read
    /// the observable state (only if called off-main).
    func snapshot(pendingOnly: Bool) -> [WorkstreamItem] {
        let slot = SnapshotSlot()
        let body: @Sendable () -> Void = { [slot] in
            MainActor.assumeIsolated {
                guard let store = FeedCoordinator.shared.store else { return }
                slot.value = pendingOnly ? store.pending : store.items
            }
        }
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
        return slot.value
    }

    /// Parses `workstreamId` in the form `<agent>-<sessionId>` and
    /// looks up the matching hook-session entry in
    /// `~/.cmuxterm/<agent>-hook-sessions.json` (written by
    /// `cmux <agent>-hook session-start`). Returns `true` if a match
    /// was found so the UI can gate the jump gesture.
    ///
    /// Actual focus (workspace.select + surface.focus) is scheduled via
    /// `FeedJumpResolver.focusIfPossible` on the main actor.
    func resolvePossibleSurface(for workstreamId: String) -> Bool {
        guard let parsed = FeedJumpResolver.parse(workstreamId) else {
            return false
        }
        return FeedJumpResolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId) != nil
    }

    /// Fires a best-effort focus for the given `workstreamId`. Returns
    /// `true` if a target was found and the focus commands were
    /// dispatched. Runs on the main actor because the focus commands
    /// touch AppKit state.
    @MainActor
    func focusIfPossible(workstreamId: String) -> Bool {
        guard let parsed = FeedJumpResolver.parse(workstreamId),
              let target = FeedJumpResolver.lookup(
                agent: parsed.agent, sessionId: parsed.sessionId
              )
        else { return false }
        FeedJumpResolver.focus(workspaceId: target.workspaceId, surfaceId: target.surfaceId)
        return true
    }

    /// Resolves `workstreamId` to a `(workspace, surface)` pair and
    /// types the user's `text` into that surface, followed by Return.
    /// Used by Stop-kind cards so the user can reply to Claude from
    /// the Feed without switching focus to the terminal.
    @MainActor
    @discardableResult
    func sendTextToWorkstream(workstreamId: String, text: String) -> Bool {
        guard let parsed = FeedJumpResolver.parse(workstreamId),
              let target = FeedJumpResolver.lookup(
                agent: parsed.agent, sessionId: parsed.sessionId
              )
        else { return false }
        FeedJumpResolver.sendText(
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId,
            text: text
        )
        return true
    }
}

/// Reads the per-agent hook session stores (`~/.cmuxterm/<agent>-hook-sessions.json`)
/// to map a feed `workstream_id` back to a cmux `(workspaceId, surfaceId)` pair.
/// The schema is the same one written by `cmux <agent>-hook session-start`.
enum FeedJumpResolver {
    struct Target: Equatable {
        let workspaceId: String
        let surfaceId: String
    }

    static func parse(_ workstreamId: String) -> (agent: String, sessionId: String)? {
        guard let dash = workstreamId.firstIndex(of: "-") else { return nil }
        let agent = String(workstreamId[..<dash])
        let sessionId = String(workstreamId[workstreamId.index(after: dash)...])
        guard !agent.isEmpty, !sessionId.isEmpty else { return nil }
        return (agent, sessionId)
    }

    static func lookup(agent: String, sessionId: String) -> Target? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("\(agent)-hook-sessions.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Stores have a consistent shape: top-level `sessions` dict keyed
        // by sessionId. Tolerate older flat layouts too.
        let sessions: [String: Any]
        if let nested = root["sessions"] as? [String: Any] {
            sessions = nested
        } else {
            sessions = root
        }
        guard let entry = sessions[sessionId] as? [String: Any],
              let workspaceId = entry["workspaceId"] as? String,
              let surfaceId = entry["surfaceId"] as? String,
              !workspaceId.isEmpty, !surfaceId.isEmpty
        else { return nil }
        return Target(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Dispatches a workspace-select + surface-focus intent. Posts
    /// through the existing cmux notification pathway so we don't need
    /// to bind directly to the TerminalController V2 handlers from the
    /// Feed layer.
    @MainActor
    static func focus(workspaceId: String, surfaceId: String) {
        NotificationCenter.default.post(
            name: .feedRequestFocus,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
            ]
        )
    }

    /// Dispatches a surface.send_text intent for the agent's terminal.
    /// The observer in AppDelegate translates it into the V2 socket
    /// call so the Feed stays decoupled from TerminalController.
    @MainActor
    static func sendText(workspaceId: String, surfaceId: String, text: String) {
        NotificationCenter.default.post(
            name: .feedRequestSendText,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
                "text": text,
            ]
        )
    }
}

extension Notification.Name {
    static let feedRequestFocus = Notification.Name("cmux.feedRequestFocus")
    static let feedRequestSendText = Notification.Name("cmux.feedRequestSendText")
}

// MARK: - Native notification banner

private extension FeedCoordinator {
    /// Posts a UNUserNotificationCenter banner with inline action buttons
    /// for the given Feed event after optional notification policy hooks run.
    /// Notification eligibility is derived only from the waiter table so
    /// resolved/timed-out requests cannot enqueue stale banners while the main
    /// queue, policy hooks, or notification center catches up.
    func postNotificationIfStillAwaiting(event: WorkstreamEvent, requestId: String) {
        Task { @MainActor [weak self] in
            guard let self, self.isAwaitingDecision(requestId: requestId) else {
                return
            }

            #if DEBUG
            let isAppActive = FeedCoordinatorTestHooks.isAppActiveOverride?() ?? NSApp.isActive
            #else
            let isAppActive = NSApp.isActive
            #endif

            // Don't pester users while the app is already up front.
            if isAppActive {
                return
            }

            #if DEBUG
            if let observer = FeedCoordinatorTestHooks.notificationPostObserver {
                observer(event, requestId)
                return
            }
            #endif

            let categoryId: String
            let title: String
            let body: String
            switch event.hookEventName {
            case .permissionRequest:
                categoryId = Self.permissionNotificationCategoryId(for: event)
                title = String(
                    localized: "feed.notification.permission.title",
                    defaultValue: "\(event.source.capitalized) permission"
                )
                body = event.toolName.map {
                    String(
                        localized: "feed.notification.permission.body",
                        defaultValue: "\($0) needs approval"
                    )
                } ?? String(
                    localized: "feed.notification.decisionNeeded",
                    defaultValue: "Decision needed"
                )
            case .exitPlanMode:
                categoryId = "CMUXFeedExitPlan"
                title = String(
                    localized: "feed.notification.exitPlan.title",
                    defaultValue: "\(event.source.capitalized) plan ready"
                )
                body = String(
                    localized: "feed.notification.exitPlan.body",
                    defaultValue: "Review and approve the plan"
                )
            case .askUserQuestion:
                categoryId = "CMUXFeedQuestion"
                title = String(
                    localized: "feed.notification.question.title",
                    defaultValue: "\(event.source.capitalized) question"
                )
                body = String(
                    localized: "feed.notification.question.body",
                    defaultValue: "Agent is asking a question"
                )
            default:
                return
            }

            let policyContext = makeFeedNotificationPolicyContext(
                event: event,
                title: title,
                body: body
            )
            let deliverDefault = { [weak self] in
                self?.deliverFeedNotificationIfStillAwaiting(
                    requestId: requestId,
                    event: event,
                    categoryId: categoryId,
                    title: title,
                    subtitle: "",
                    body: body,
                    effects: policyContext.envelope.effects
                )
            }

            guard !policyContext.hooks.isEmpty else {
                deliverDefault()
                return
            }

            let authorizedHooks = await NotificationPolicyHookAuthorizer.authorize(
                policyContext.hooks,
                globalConfigPath: policyContext.globalConfigPath
            )
            guard self.isAwaitingDecision(requestId: requestId) else { return }
            guard !authorizedHooks.isEmpty else {
                deliverDefault()
                return
            }

            let result = await TerminalNotificationPolicyEngine.evaluate(
                envelope: policyContext.envelope,
                hooks: authorizedHooks
            )
            guard self.isAwaitingDecision(requestId: requestId) else { return }
            switch result {
            case .success(let envelope):
                let payload = envelope.notification
                self.deliverFeedNotificationIfStillAwaiting(
                    requestId: requestId,
                    event: event,
                    categoryId: categoryId,
                    title: payload.title,
                    subtitle: payload.subtitle,
                    body: payload.body,
                    effects: envelope.effects
                )
            case .failure(let failure):
                deliverDefault()
                TerminalNotificationStore.shared.reportNotificationHookFailure(failure)
            }
        }
    }

    private static func permissionNotificationCategoryId(for event: WorkstreamEvent) -> String {
        let source = WorkstreamSource(wireName: event.source) ?? .claude
        let supportsOnce = FeedPermissionActionPolicy.supportsOncePermissionMode(
            source: source,
            toolInputJSON: event.toolInputJSON
        )
        let supportsAlways = FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
            source: source,
            toolInputJSON: event.toolInputJSON
        )
        let supportsAll = FeedPermissionActionPolicy.supportsAllPermissionMode(
            source: source,
            toolInputJSON: event.toolInputJSON
        )
        var suffix = ""
        if supportsOnce { suffix += "Once" }
        if supportsAlways { suffix += "Always" }
        if supportsAll { suffix += "All" }
        return suffix.isEmpty ? "CMUXFeedPermissionDeny" : "CMUXFeedPermission\(suffix)"
    }

    @MainActor
    func deliverFeedNotificationIfStillAwaiting(
        requestId: String,
        event: WorkstreamEvent,
        categoryId: String,
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard isAwaitingDecision(requestId: requestId),
              effects.desktop || effects.sound || effects.command
        else { return }

        if !effects.desktop {
            runFallbackEffectsIfStillAwaiting(
                requestId: requestId,
                title: title,
                subtitle: subtitle,
                body: body,
                effects: effects,
                runCommand: true
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
        content.categoryIdentifier = categoryId
        content.userInfo = [
            "requestId": requestId,
            "workstreamId": event.sessionId,
        ]

        let request = UNNotificationRequest(
            identifier: "feed.\(requestId)",
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor [weak self] in
                guard let self, self.isAwaitingDecision(requestId: requestId) else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.addNotificationIfStillAwaiting(
                        center: center,
                        request: request,
                        requestId: requestId,
                        effects: effects
                    )
                case .notDetermined:
                    var granted = false
                    var requestFailed = false
                    do {
                        granted = try await center.requestAuthorization(options: [.alert, .sound])
                    } catch {
                        requestFailed = true
                    }
                    guard self.isAwaitingDecision(requestId: requestId) else { return }
                    if granted {
                        self.addNotificationIfStillAwaiting(
                            center: center,
                            request: request,
                            requestId: requestId,
                            effects: effects
                        )
                    } else {
                        // A non-grant without an error is the user declining
                        // the prompt just now: honor the fresh denial on this
                        // very notification. A request error is not a user
                        // decision, so the fallback stays audible (fail-open).
                        self.runFallbackEffectsIfStillAwaiting(
                            requestId: requestId,
                            title: title,
                            subtitle: subtitle,
                            body: body,
                            effects: TerminalNotificationStore.fallbackEffects(
                                effects,
                                authorizationState: requestFailed ? .unknown : .denied
                            ),
                            runCommand: false
                        )
                    }
                default:
                    self.runFallbackEffectsIfStillAwaiting(
                        requestId: requestId,
                        title: title,
                        subtitle: subtitle,
                        body: body,
                        effects: TerminalNotificationStore.fallbackEffects(
                            effects,
                            authorizationState: TerminalNotificationStore.authorizationState(
                                from: settings.authorizationStatus
                            )
                        ),
                        runCommand: false
                    )
                }
            }
        }
    }

    @MainActor
    func addNotificationIfStillAwaiting(
        center: UNUserNotificationCenter,
        request: UNNotificationRequest,
        requestId: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard isAwaitingDecision(requestId: requestId) else { return }
        let title = request.content.title
        let subtitle = request.content.subtitle
        let body = request.content.body
        center.add(request) { error in
            let didFail = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isAwaitingDecision(requestId: requestId) {
                    self.cancelNotification(requestId: requestId)
                    return
                }
                if didFail {
                    self.runFallbackEffectsIfStillAwaiting(
                        requestId: requestId,
                        title: title,
                        subtitle: subtitle,
                        body: body,
                        effects: effects,
                        runCommand: false
                    )
                    return
                }
                if effects.command {
                    NotificationSoundSettings.runCustomCommand(
                        title: title,
                        subtitle: subtitle,
                        body: body
                    )
                }
            }
        }
    }

    @MainActor
    func runFallbackEffectsIfStillAwaiting(
        requestId: String,
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool
    ) {
        guard isAwaitingDecision(requestId: requestId) else { return }
        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: title,
            subtitle: subtitle,
            body: body,
            effects: effects, runCommand: runCommand
        )
    }

    func cancelNotification(requestId: String) {
        let identifier = "feed.\(requestId)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequestsOffMain(withIdentifiers: [identifier])
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [identifier])
    }
}

private struct FeedNotificationPolicyContext {
    let envelope: TerminalNotificationPolicyEnvelope
    let hooks: [CmuxResolvedNotificationHook]
    let globalConfigPath: String?
}

@MainActor
private func makeFeedNotificationPolicyContext(
    event: WorkstreamEvent,
    title: String,
    body: String
) -> FeedNotificationPolicyContext {
    let appDelegate = AppDelegate.shared
    let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:))
    let context = workspaceID.flatMap { appDelegate?.contextContainingTabId($0) }
        ?? appDelegate?.mainWindowContexts.values.first(where: { $0.cmuxConfigStore != nil })
    let workspace = workspaceID.flatMap { id in
        context?.tabManager.tabs.first(where: { $0.id == id })
    }
    let cwd = normalizedFeedNotificationCWD(event.cwd)
        ?? workspace?.surfaceTabBarDirectory
        ?? workspace?.currentDirectory
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    var effects = TerminalNotificationPolicyEffects()
    effects.desktop = true
    effects.record = false
    effects.markUnread = false
    effects.reorderWorkspace = false
    effects.sound = false
    effects.command = false
    effects.paneFlash = false

    return FeedNotificationPolicyContext(
        envelope: TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: event.workspaceId ?? event.sessionId,
                surfaceId: nil,
                title: title,
                subtitle: "",
                body: body
            ),
            context: TerminalNotificationPolicyContext(
                cwd: cwd,
                configPath: nil,
                hookId: nil,
                appFocused: AppFocusState.isAppFocused(),
                focusedPanel: false
            ),
            effects: effects
        ),
        hooks: context?.cmuxConfigStore?.notificationHooks(startingFrom: workspace?.isRemoteWorkspace == true ? nil : (normalizedFeedNotificationCWD(event.cwd) ?? workspace?.surfaceTabBarDirectory)) ?? [],
        globalConfigPath: context?.cmuxConfigStore?.globalConfigPath
    )
}

private func normalizedFeedNotificationCWD(_ cwd: String?) -> String? {
    guard let cwd else { return nil }
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// JSON-shape helpers used by the V2 `feed.*` socket handlers.
enum FeedSocketEncoding {
    private static let primaryTextLimit = 8_000
    private static let secondaryTextLimit = 2_000

    static func payload(for result: FeedCoordinator.IngestBlockingResult) -> [String: Any] {
        switch result {
        case .acknowledged(let itemId):
            var dict: [String: Any] = ["status": "acknowledged"]
            if let itemId { dict["item_id"] = itemId.uuidString }
            return dict
        case .resolved(let itemId, let decision):
            var dict: [String: Any] = [
                "status": "resolved",
                "decision": decisionDict(decision)
            ]
            if let itemId { dict["item_id"] = itemId.uuidString }
            return dict
        case .timedOut(let itemId):
            var dict: [String: Any] = ["status": "timed_out"]
            if let itemId { dict["item_id"] = itemId.uuidString }
            return dict
        }
    }

    static func decisionDict(_ decision: WorkstreamDecision) -> [String: Any] {
        switch decision {
        case .permission(let mode):
            return ["kind": "permission", "mode": mode.rawValue]
        case .exitPlan(let mode, let feedback):
            var dict: [String: Any] = ["kind": "exit_plan", "mode": mode.rawValue]
            if let feedback, !feedback.isEmpty {
                dict["feedback"] = feedback
            }
            return dict
        case .question(let selections):
            return ["kind": "question", "selections": selections]
        }
    }

    private static func limitedText(_ value: String, limit: Int) -> (text: String, truncated: Bool) {
        guard value.count > limit else { return (value, false) }
        let end = value.index(value.startIndex, offsetBy: max(limit - 3, 0))
        return (String(value[..<end]) + "...", true)
    }

    private static func assignLimitedText(
        _ value: String,
        key: String,
        to dict: inout [String: Any],
        limit: Int = 8_000
    ) {
        let limited = limitedText(value, limit: limit)
        dict[key] = limited.text
        if limited.truncated {
            dict["\(key)_truncated"] = true
        }
    }

    private static func questionDict(_ question: WorkstreamQuestionPrompt) -> [String: Any] {
        var dict: [String: Any] = [
            "id": question.id,
            "multi_select": question.multiSelect,
        ]
        if let header = question.header {
            assignLimitedText(header, key: "header", to: &dict, limit: secondaryTextLimit)
        }
        assignLimitedText(question.prompt, key: "prompt", to: &dict, limit: primaryTextLimit)
        dict["options"] = question.options.map { option in
            var optionDict: [String: Any] = [
                "id": option.id,
                "label": limitedText(option.label, limit: secondaryTextLimit).text,
            ]
            if let description = option.description {
                assignLimitedText(description, key: "description", to: &optionDict, limit: secondaryTextLimit)
            }
            return optionDict
        }
        return dict
    }

    static func itemDict(_ item: WorkstreamItem) -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": item.id.uuidString,
            "workstream_id": item.workstreamId,
            "source": item.source.rawValue,
            "kind": item.kind.rawValue,
            "created_at": isoFormatter.string(from: item.createdAt),
            "updated_at": isoFormatter.string(from: item.updatedAt),
        ]
        if let cwd = item.cwd { dict["cwd"] = cwd }
        if let title = item.title { dict["title"] = title }
        switch item.status {
        case .pending:
            dict["status"] = "pending"
        case .resolved(let decision, let at):
            dict["status"] = "resolved"
            dict["decision"] = decisionDict(decision)
            dict["resolved_at"] = isoFormatter.string(from: at)
        case .expired(let at):
            dict["status"] = "expired"
            dict["resolved_at"] = isoFormatter.string(from: at)
        case .telemetry:
            dict["status"] = "telemetry"
        }
        switch item.payload {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            dict["request_id"] = requestId
            dict["tool_name"] = toolName
            if let capabilityJSON = FeedPermissionActionPolicy.codexCapabilityToolInputJSON(
                source: item.source,
                toolInputJSON: toolInputJSON
            ) {
                dict["tool_input_capabilities"] = capabilityJSON
            }
            assignLimitedText(toolInputJSON, key: "tool_input", to: &dict)
            if let pattern { dict["pattern"] = pattern }
        case .exitPlan(let requestId, let plan, let defaultMode):
            dict["request_id"] = requestId
            assignLimitedText(plan, key: "plan", to: &dict)
            dict["plan_summary"] = plan.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            dict["default_mode"] = defaultMode.rawValue
        case .question(let requestId, let questions):
            dict["request_id"] = requestId
            dict["questions"] = questions.map(questionDict)
            if let firstQuestion = questions.first {
                assignLimitedText(firstQuestion.prompt, key: "question_prompt", to: &dict)
                dict["question_multi_select"] = firstQuestion.multiSelect
                dict["question_options"] = firstQuestion.options.map { option in
                    var optionDict: [String: Any] = [
                        "id": option.id,
                        "label": limitedText(option.label, limit: secondaryTextLimit).text,
                    ]
                    if let description = option.description {
                        assignLimitedText(description, key: "description", to: &optionDict, limit: secondaryTextLimit)
                    }
                    return optionDict
                }
            }
        case .toolUse(let toolName, let toolInputJSON):
            dict["tool_name"] = toolName
            assignLimitedText(toolInputJSON, key: "tool_input", to: &dict)
        case .toolResult(let toolName, let resultJSON, let isError):
            dict["tool_name"] = toolName
            assignLimitedText(resultJSON, key: "tool_result", to: &dict)
            dict["tool_result_is_error"] = isError
        case .userPrompt(let text), .assistantMessage(let text):
            assignLimitedText(text, key: "text", to: &dict)
        case .sessionStart, .sessionEnd:
            break
        case .stop(let reason):
            if let reason { assignLimitedText(reason, key: "reason", to: &dict, limit: secondaryTextLimit) }
        case .todos(let todos):
            dict["todos"] = todos.map { todo in
                [
                    "id": todo.id,
                    "content": limitedText(todo.content, limit: secondaryTextLimit).text,
                    "state": todo.state.rawValue,
                ]
            }
        }
        return dict
    }
}
