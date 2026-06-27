import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
@preconcurrency import UserNotifications
import CmuxFeedUI
import CmuxFoundation
import CmuxNotifications
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

    /// Pending blocking-hook waiters keyed by request id. The registry owns a
    /// semaphore plus a slot for the resolved decision per waiter; the reply
    /// handler signals the semaphore after filling the slot.
    private let waiterRegistry = BlockingDecisionWaiterRegistry()

    /// Owns the kqueue-backed per-PID exit watchers. When an agent process
    /// dies, the watcher marks every pending item for that PID as `.expired`
    /// on the store and cancels its source. Keyed by PID inside the watcher so
    /// the same agent spawning multiple prompts only installs one watcher.
    let pidExitWatcher = WorkstreamPidExitWatcher()

    /// Routes socket-layer Feed requests (`feed.jump`, `feed.reply`, snapshot
    /// reads) to the hook-session resolver and the observable store. Holds one
    /// injected resolver instead of constructing one per call.
    let socketRouter = FeedSocketRouter()

    /// Owns the in-app attention overlay (needs-input sidebar badge, workspace
    /// elevation, bell) for blocking feed decisions. Main-actor isolated:
    /// touched only from the `@MainActor` ingest/conclude sections.
    @MainActor let attentionCoordinator = FeedAttentionCoordinator()

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

    /// Installs a one-shot kqueue watcher for `ppid` on the owning store. The
    /// handler fires the moment the kernel observes process exit (or
    /// immediately if `ppid` is already dead), marks every pending item for
    /// that PID as `.expired`, and cancels the source. Idempotent: subsequent
    /// calls with the same PID no-op.
    @MainActor
    func armPidWatcher(ppid: Int) {
        pidExitWatcher.arm(ppid: ppid, store: store)
    }

    /// Ingests a wire-frame event and, when `waitTimeout` > 0, blocks the
    /// current (non-main) thread until the item is resolved or the
    /// timeout elapses.
    func ingestBlocking(
        event: WorkstreamEvent,
        waitTimeout: TimeInterval
    ) -> WorkstreamIngestBlockingResult {
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

        // Register the waiter before the store sees the event so a very
        // fast reply can't slip through.
        let semaphore = waiterRegistry.register(requestId: requestId)

        // Hop to main to actually insert the item + install the
        // kqueue watcher for the agent's PID. The watcher handler
        // caps the pending lifetime to the agent process lifetime
        // — no polling, no leaked cards when the agent is killed.
        let itemIdSlot = UnsafeItemIdSlot()
        let resolvedAttentionTarget = event.hookEventName.isBlockingDecision
            ? event.resolveAttentionTarget()
            : nil
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
                if let target = FeedCoordinator.shared.attentionCoordinator.surfaceBlockingDecisionAttention(
                    event: event,
                    resolved: resolvedAttentionTarget
                ) {
                    FeedCoordinator.shared.waiterRegistry.setAttentionTarget(target, requestId: requestId)
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

        let w = waiterRegistry.removeWaiter(requestId: requestId)

        switch waitResult {
        case .success:
            if let decision = w?.resolvedDecision {
                // `deliverReply` concludes the attention overlay on resolve.
                return .resolved(itemId: itemIdSlot.value, decision: decision)
            }
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(w?.resolvedAttentionTarget)
            expireTimedOutItem(itemIdSlot.value)
            return .timedOut(itemId: itemIdSlot.value)
        case .timedOut:
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(w?.resolvedAttentionTarget)
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
                FeedCoordinator.shared.attentionCoordinator.concludeBlockingDecisionAttention(target)
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
        let attentionTarget = waiterRegistry.deliverDecision(decision, requestId: requestId)

        // The user decided: conclude the needs-input overlay so the agent's
        // running/idle state shows through (refcounted so an overlapping
        // decision on the same panel keeps it lit until it too concludes).
        concludeAttentionOnMain(attentionTarget)

        let resolve: @Sendable () -> Void = { [requestId, decision] in
            MainActor.assumeIsolated {
                let store = FeedCoordinator.shared.store
                guard let store else { return }
                if let itemId = store.items.mostRecentActionableItemID(forRequestID: requestId) {
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
        waiterRegistry.isAwaitingDecision(requestId: requestId)
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
}

/// Tiny box so the `DispatchQueue.main.sync` closure can mutate an
/// `UUID?` without a capture warning.
private final class UnsafeItemIdSlot: @unchecked Sendable {
    var value: UUID?
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
                let permissionSource = WorkstreamSource(wireName: event.source) ?? .claude
                categoryId = NotificationFeedPermissionCapabilities(
                    supportsOnce: FeedPermissionActionPolicy.supportsOncePermissionMode(
                        source: permissionSource,
                        toolInputJSON: event.toolInputJSON
                    ),
                    supportsAlways: FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                        source: permissionSource,
                        toolInputJSON: event.toolInputJSON
                    ),
                    supportsAll: FeedPermissionActionPolicy.supportsAllPermissionMode(
                        source: permissionSource,
                        toolInputJSON: event.toolInputJSON
                    )
                ).notificationCategoryIdentifier
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

            let policyContext = self.makeNotificationPolicyContext(
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

            let authorizedHooks = await NotificationPolicyHookAuthorizer(trust: .shared).authorize(
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

// MARK: - Notification policy context

private extension FeedCoordinator {
    struct NotificationPolicyContext {
        let envelope: TerminalNotificationPolicyEnvelope
        let hooks: [CmuxResolvedNotificationHook]
        let globalConfigPath: String?
    }

    @MainActor
    func makeNotificationPolicyContext(
        event: WorkstreamEvent,
        title: String,
        body: String
    ) -> NotificationPolicyContext {
        let appDelegate = AppDelegate.shared
        let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:))
        let context = workspaceID.flatMap { appDelegate?.contextContainingTabId($0) }
            ?? appDelegate?.firstContextWithConfigStore()
        let configStore = context.flatMap { appDelegate?.configStore(for: $0) }
        let workspace = workspaceID.flatMap { id in
            context?.tabManager.tabs.first(where: { $0.id == id })
        }
        let cwd = event.cwd?.whitespaceTrimmedNilIfEmpty
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

        return NotificationPolicyContext(
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
            hooks: configStore?.notificationHooks(startingFrom: cwd) ?? [],
            globalConfigPath: configStore?.globalConfigPath
        )
    }
}
