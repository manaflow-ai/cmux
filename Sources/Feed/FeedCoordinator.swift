import AppKit
import CMUXWorkstream
import Foundation
@preconcurrency import UserNotifications

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
    @MainActor private var attentionTargets: [String: AttentionTarget] = [:]

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
        guard let requestId = event.requestId, waitTimeout > 0 else {
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
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                FeedCoordinator.shared.store.ingest(event)
                itemIdSlot.value = FeedCoordinator.shared.store.items.last?.id
                if let ppid = event.ppid, ppid > 0 {
                    FeedCoordinator.shared.armPidWatcher(ppid: ppid)
                }
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(event: event, requestId: requestId)
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
                clearBlockingDecisionAttention(requestId: requestId)
                return .resolved(itemId: itemIdSlot.value, decision: decision)
            }
            cancelNotification(requestId: requestId)
            expireTimedOutItem(itemIdSlot.value)
            clearBlockingDecisionAttention(requestId: requestId)
            return .timedOut(itemId: itemIdSlot.value)
        case .timedOut:
            cancelNotification(requestId: requestId)
            expireTimedOutItem(itemIdSlot.value)
            clearBlockingDecisionAttention(requestId: requestId)
            return .timedOut(itemId: itemIdSlot.value)
        }
    }

    /// Called by the `feed.*.reply` handlers. Marks the corresponding
    /// item resolved on the main-actor store and wakes any waiter.
    func deliverReply(requestId: String, decision: WorkstreamDecision) {
        waiterLock.lock()
        if let waiter = waiters[requestId] {
            waiter.decision = decision
            waiter.semaphore.signal()
        }
        waiterLock.unlock()

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
        clearBlockingDecisionAttention(requestId: requestId)
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

    @MainActor
    private func surfaceBlockingDecisionAttention(event: WorkstreamEvent, requestId: String) {
        guard Self.isBlockingDecision(event),
              let statusKey = Self.statusKey(for: event.source),
              let target = resolveAttentionTarget(event: event, statusKey: statusKey)
        else { return }

        #if DEBUG
        FeedCoordinatorTestHooks.attentionObserver?(event, requestId, statusKey, target.workspaceId, target.surfaceId)
        #endif

        guard let manager = Self.tabManager(containing: target.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == target.workspaceId })
        else { return }

        let existingWorkspaceStatusTarget = attentionTargets.values.first {
            $0.workspaceId == target.workspaceId &&
                $0.statusKey == target.statusKey
        }
        let existingPanelLifecycleTarget = attentionTargets.values.first {
            $0.workspaceId == target.workspaceId &&
                $0.surfaceId == target.surfaceId &&
                $0.statusKey == target.statusKey
        }
        let resolvedTarget = AttentionTarget(
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId,
            statusKey: target.statusKey,
            previousStatusEntry: existingWorkspaceStatusTarget?.previousStatusEntry ?? workspace.statusEntries[statusKey],
            previousLifecycle: existingPanelLifecycleTarget?.previousLifecycle ?? target.surfaceId.flatMap {
                workspace.agentLifecycle(key: target.statusKey, panelId: $0)
            }
        )
        attentionTargets[requestId] = resolvedTarget

        workspace.statusEntries[statusKey] = SidebarStatusEntry(
            key: statusKey,
            value: String(localized: "feed.status.needsInput", defaultValue: "Needs input"),
            icon: "bell.fill",
            color: "#4C8DFF",
            priority: 100
        )
        if let surfaceId = target.surfaceId {
            workspace.setAgentLifecycle(
                key: statusKey,
                panelId: surfaceId,
                lifecycle: .needsInput
            )
        }
        if WorkspaceAutoReorderSettings.isEnabled() {
            manager.moveTabToTopForNotification(target.workspaceId)
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func clearBlockingDecisionAttention(requestId: String) {
        Task { @MainActor in
            FeedCoordinator.shared.clearBlockingDecisionAttentionOnMain(requestId: requestId)
        }
    }

    @MainActor
    private func clearBlockingDecisionAttentionOnMain(requestId: String) {
        guard let target = attentionTargets.removeValue(forKey: requestId),
              let manager = Self.tabManager(containing: target.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == target.workspaceId })
        else { return }
        let hasWorkspaceSiblingPendingDecision = attentionTargets.values.contains {
            $0.workspaceId == target.workspaceId &&
                $0.statusKey == target.statusKey
        }
        let hasPanelSiblingPendingDecision = attentionTargets.values.contains {
            $0.workspaceId == target.workspaceId &&
                $0.surfaceId == target.surfaceId &&
                $0.statusKey == target.statusKey
        }
        if !hasWorkspaceSiblingPendingDecision,
           let entry = workspace.statusEntries[target.statusKey],
           entry.value == String(localized: "feed.status.needsInput", defaultValue: "Needs input"),
           entry.icon == "bell.fill",
           entry.color == "#4C8DFF" {
            if let previousStatusEntry = target.previousStatusEntry {
                workspace.statusEntries[target.statusKey] = previousStatusEntry
            } else {
                workspace.statusEntries.removeValue(forKey: target.statusKey)
            }
        }
        if !hasPanelSiblingPendingDecision,
           let surfaceId = target.surfaceId,
           workspace.agentLifecycle(key: target.statusKey, panelId: surfaceId) == .needsInput {
            if let previousLifecycle = target.previousLifecycle {
                workspace.setAgentLifecycle(key: target.statusKey, panelId: surfaceId, lifecycle: previousLifecycle)
            } else {
                _ = workspace.clearAgentLifecycle(key: target.statusKey, panelId: surfaceId)
            }
        }
    }

    @MainActor
    private func resolveAttentionTarget(event: WorkstreamEvent, statusKey: String) -> AttentionTarget? {
        let resolved = FeedJumpResolver.parse(event.sessionId).flatMap {
            FeedJumpResolver.lookup(agent: $0.agent, sessionId: $0.sessionId)
        }
        if let workspaceId = event.workspaceId.flatMap(UUID.init(uuidString:)) {
            var resolvedSurfaceId: UUID?
            if resolved?.workspaceId == workspaceId.uuidString {
                resolvedSurfaceId = resolved.flatMap { UUID(uuidString: $0.surfaceId) }
            }
            return AttentionTarget(
                workspaceId: workspaceId,
                surfaceId: resolvedSurfaceId,
                statusKey: statusKey,
                previousStatusEntry: nil,
                previousLifecycle: nil
            )
        }
        let workspaceString = resolved?.workspaceId
        guard let workspaceId = workspaceString.flatMap(UUID.init(uuidString:)) else { return nil }
        let surfaceId = resolved.flatMap { UUID(uuidString: $0.surfaceId) }
        return AttentionTarget(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            statusKey: statusKey,
            previousStatusEntry: nil,
            previousLifecycle: nil
        )
    }

    @MainActor
    private static func tabManager(containing workspaceId: UUID) -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        if let manager = app.tabManagerFor(tabId: workspaceId) {
            return manager
        }
        if let manager = app.tabManager,
           manager.tabs.contains(where: { $0.id == workspaceId }) {
            return manager
        }
        return nil
    }

    private static func isBlockingDecision(_ event: WorkstreamEvent) -> Bool {
        switch event.hookEventName {
        case .permissionRequest, .askUserQuestion, .exitPlanMode:
            return event.requestId != nil
        default:
            return false
        }
    }

    private static func statusKey(for source: String) -> String? {
        switch source {
        case "claude", "claude_code":
            return "claude_code"
        case "agy":
            return "antigravity"
        case "rovo":
            return "rovodev"
        case "amp", "antigravity", "codebuddy", "codex", "copilot", "cursor", "factory", "gemini", "grok", "kiro", "opencode", "pi", "qoder", "rovodev":
            return source
        case "hermes", "hermes-agent":
            return "hermes-agent"
        default:
            return nil
        }
    }

    enum IngestBlockingResult {
        case acknowledged(itemId: UUID?)
        case resolved(itemId: UUID?, decision: WorkstreamDecision)
        case timedOut(itemId: UUID?)
    }
}

private final class PendingWaiter: @unchecked Sendable {
    let semaphore: DispatchSemaphore
    var decision: WorkstreamDecision?

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
    static var attentionObserver: (@Sendable (WorkstreamEvent, String, String, UUID, UUID?) -> Void)?
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

    private static let knownAgentPrefixes = [
        "hermes-agent",
        "antigravity",
        "codebuddy",
        "claude_code",
        "rovodev",
        "claude",
        "cursor",
        "factory",
        "gemini",
        "opencode",
        "codex",
        "grok",
        "kiro",
        "qoder",
        "copilot",
        "hermes",
        "agy",
        "amp",
        "rovo",
        "pi",
    ]

    static func parse(_ workstreamId: String) -> (agent: String, sessionId: String)? {
        for agent in knownAgentPrefixes {
            let prefix = "\(agent)-"
            guard workstreamId.hasPrefix(prefix) else { continue }
            let sessionId = String(workstreamId.dropFirst(prefix.count))
            guard !sessionId.isEmpty else { return nil }
            return (agent, sessionId)
        }
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
                categoryId = "CMUXFeedPermission"
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
                effects: effects
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
                    let granted = (
                        try? await center.requestAuthorization(options: [.alert, .sound])
                    ) ?? false
                    guard self.isAwaitingDecision(requestId: requestId) else { return }
                    if granted {
                        self.addNotificationIfStillAwaiting(
                            center: center,
                            request: request,
                            requestId: requestId,
                            effects: effects
                        )
                    } else {
                        self.runFallbackEffectsIfStillAwaiting(
                            requestId: requestId,
                            title: title,
                            subtitle: subtitle,
                            body: body,
                            effects: effects
                        )
                    }
                default:
                    self.runFallbackEffectsIfStillAwaiting(
                        requestId: requestId,
                        title: title,
                        subtitle: subtitle,
                        body: body,
                        effects: effects
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
                        effects: effects
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
        effects: TerminalNotificationPolicyEffects
    ) {
        guard isAwaitingDecision(requestId: requestId) else { return }
        if effects.sound {
            NotificationSoundSettings.playSelectedSound()
        }
        if effects.command {
            NotificationSoundSettings.runCustomCommand(
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
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
        hooks: context?.cmuxConfigStore?.notificationHooks(startingFrom: cwd) ?? [],
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
