import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxNotifications
import Foundation
@preconcurrency import UserNotifications
import CmuxSettings
import CmuxSidebar

private enum FeedEventAcceptance: Sendable {
    case accepted(event: WorkstreamEvent, itemId: UUID)
    case notFound
    case unavailable
}

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
    /// Last workspace that each workstream updated. This is a fast path for
    /// task re-homing; persisted row ownership remains the correctness source.
    @MainActor var lastTodoWorkspaceByWorkstream: [String: UUID] = [:]
    @MainActor private var todoWorkspaceRecency: [String] = []
    @MainActor private let maxTrackedTodoWorkstreams = 128
    @MainActor private var todoRecoveryEpochByWorkstream: [String: UInt64] = [:]
    @MainActor private var todoRecoveryRecency: [String] = []
    @MainActor private var dispatchedTaskOwnersByTargetWorkspace: [UUID: [DispatchedTaskOwner]] = [:]
    @MainActor private var dispatchedTaskOwnerRecency: [UUID] = []
    @MainActor private var dispatchTargetRecoveryScans: Set<UUID> = []
    @MainActor private let maxTrackedDispatchTargets = 128
    @MainActor private var userNotificationCenter: (any UserNotificationCenterServing)?

    /// The bounded notification-center boundary. `install(store:)` injects it;
    /// the shared store's service covers the pre-install window.
    @MainActor private var resolvedUserNotificationCenter: any UserNotificationCenterServing {
        userNotificationCenter ?? TerminalNotificationStore.shared.userNotificationCenter
    }

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

    /// Every accepted Feed path crosses this lane before insertion and `received` publication.
    private let feedIngressDeliveryLane = FeedIngressDeliveryLane()

    /// In-flight blocking decisions whose needs-input overlay is currently lit,
    /// keyed by ``FeedAttentionTarget``. Panel keys stay stable while their live
    /// owner changes; each state retains only a fallback owner for cleanup when
    /// the panel is temporarily absent from every live container registry.
    /// Main-actor isolated: read/written only from the `@MainActor` attention
    /// methods.
    @MainActor private var pendingAttentionStates: [FeedAttentionTarget: AttentionOverlayState] = [:]

    /// Tail of the serialized `CMUXFeedQuestion.` category mutation chain.
    /// `UNUserNotificationCenter` has no atomic category merge, so every
    /// mutation is a get→filter→set round trip; two concurrent round trips
    /// (mint racing mint, or mint racing cancel) each capture a stale snapshot
    /// and the later `set` silently drops the earlier write. The coordinator
    /// is the sole owner of this category namespace, and every mutation
    /// appends here so round trips never interleave.
    @MainActor private var questionCategoryUpdates: Task<Void, Never>?

    private init() {}

    /// Must be called once at app launch to install the store.
    @MainActor
    func install(
        store: WorkstreamStore,
        userNotificationCenter: (any UserNotificationCenterServing)? = nil
    ) {
        self.store = store
        // Resolved here rather than as a default argument: default-argument
        // expressions evaluate outside the method's main-actor isolation.
        self.userNotificationCenter = userNotificationCenter
            ?? TerminalNotificationStore.shared.userNotificationCenter
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

    @MainActor
    private func acceptOnMainActor(
        _ event: WorkstreamEvent
    ) -> FeedEventAcceptance {
        switch resolveDeliveryTarget(for: [event]) {
        case .accepted(let events):
            guard let revalidatedEvent = events.first,
                  let itemId = ingestRevalidatedOnMainActor(revalidatedEvent) else {
                return .unavailable
            }
            return .accepted(event: revalidatedEvent, itemId: itemId)
        case .notFound:
            return .notFound
        case .unavailable:
            return .unavailable
        }
    }

    @MainActor
    func ingestRevalidatedOnMainActor(_ event: WorkstreamEvent) -> UUID? {
        guard let store else { return nil }
        recoverAgentTodosIfNeeded(for: event)
        store.ingest(event)
        if let item = store.items.last {
            applyAgentTodos(from: item, event: event)
        }
        if event.hookEventName == .sessionEnd {
            forgetTodoWorkspace(for: event.sessionId)
        }
        if let ppid = event.ppid, ppid > 0 {
            armPidWatcher(ppid: ppid)
        }
        return store.items.last?.id
    }

    @MainActor
    func recordTodoWorkspace(workstreamId: String, workspaceID: UUID) {
        lastTodoWorkspaceByWorkstream[workstreamId] = workspaceID
        todoWorkspaceRecency.removeAll { $0 == workstreamId }
        todoWorkspaceRecency.append(workstreamId)
        guard todoWorkspaceRecency.count > maxTrackedTodoWorkstreams else { return }
        let overflow = todoWorkspaceRecency.count - maxTrackedTodoWorkstreams
        for old in todoWorkspaceRecency.prefix(overflow) {
            lastTodoWorkspaceByWorkstream.removeValue(forKey: old)
        }
        todoWorkspaceRecency.removeFirst(overflow)
    }

    @MainActor
    private func forgetTodoWorkspace(for workstreamId: String) {
        lastTodoWorkspaceByWorkstream.removeValue(forKey: workstreamId)
        todoWorkspaceRecency.removeAll { $0 == workstreamId }
        todoRecoveryEpochByWorkstream.removeValue(forKey: workstreamId)
        todoRecoveryRecency.removeAll { $0 == workstreamId }
    }

    @MainActor
    func registerDispatchedTask(
        itemID: UUID,
        sourceWorkspaceID: UUID,
        targetWorkspaceID: UUID
    ) {
        let owner = DispatchedTaskOwner(itemID: itemID, sourceWorkspaceID: sourceWorkspaceID)
        var owners = dispatchedTaskOwnersByTargetWorkspace[targetWorkspaceID] ?? []
        guard !owners.contains(owner) else { return }
        owners.append(owner)
        dispatchedTaskOwnersByTargetWorkspace[targetWorkspaceID] = owners
        touchDispatchTarget(targetWorkspaceID)
    }

    @MainActor
    func dispatchedTaskOwners(for targetWorkspaceID: UUID) -> [DispatchedTaskOwner] {
        dispatchedTaskOwnersByTargetWorkspace[targetWorkspaceID] ?? []
    }

    @MainActor
    func markDispatchTargetRecoveryScan(_ targetWorkspaceID: UUID) -> Bool {
        guard dispatchTargetRecoveryScans.insert(targetWorkspaceID).inserted else { return false }
        touchDispatchTarget(targetWorkspaceID)
        return true
    }

    @MainActor
    func markTodoRecoveryAttempt(
        _ workstreamId: String,
        recoveryEpoch: UInt64
    ) -> Bool {
        guard todoRecoveryEpochByWorkstream[workstreamId] != recoveryEpoch else { return false }
        todoRecoveryEpochByWorkstream[workstreamId] = recoveryEpoch
        todoRecoveryRecency.removeAll { $0 == workstreamId }
        todoRecoveryRecency.append(workstreamId)
        if todoRecoveryRecency.count > maxTrackedTodoWorkstreams {
            let overflow = todoRecoveryRecency.count - maxTrackedTodoWorkstreams
            for old in todoRecoveryRecency.prefix(overflow) {
                todoRecoveryEpochByWorkstream.removeValue(forKey: old)
            }
            todoRecoveryRecency.removeFirst(overflow)
        }
        return true
    }

    @MainActor
    private func touchDispatchTarget(_ targetWorkspaceID: UUID) {
        dispatchedTaskOwnerRecency.removeAll { $0 == targetWorkspaceID }
        dispatchedTaskOwnerRecency.append(targetWorkspaceID)
        guard dispatchedTaskOwnerRecency.count > maxTrackedDispatchTargets else { return }
        let overflow = dispatchedTaskOwnerRecency.count - maxTrackedDispatchTargets
        for old in dispatchedTaskOwnerRecency.prefix(overflow) {
            dispatchedTaskOwnersByTargetWorkspace.removeValue(forKey: old)
            dispatchTargetRecoveryScans.remove(old)
        }
        dispatchedTaskOwnerRecency.removeFirst(overflow)
    }

    struct DispatchedTaskOwner: Sendable, Equatable {
        let itemID: UUID
        let sourceWorkspaceID: UUID
    }

    /// Runs synchronous acknowledged ingress on the same ordered lane as zero-wait telemetry.
    func performAcceptedEventDelivery<Result: Sendable>(
        for events: [WorkstreamEvent],
        timeout: TimeInterval,
        _ delivery: @escaping @Sendable (FeedIngressSynchronousResult<Result>) -> Void
    ) -> Result? {
        guard !events.isEmpty else { return nil }
        return feedIngressDeliveryLane.perform(
            metadata: Self.ingressMetadata(
                for: events,
                importance: .acknowledged
            ),
            timeout: timeout,
            delivery
        )
    }

    /// Ingests a wire-frame event and, when `waitTimeout` > 0, blocks the
    /// current (non-main) thread until the item is resolved or the
    /// timeout elapses.
    func ingestBlocking(
        event: WorkstreamEvent,
        waitTimeout: TimeInterval,
        onAcceptedOnMainActor: @escaping @MainActor @Sendable (WorkstreamEvent) -> Void = { _ in },
        onAccepted: @escaping @Sendable (WorkstreamEvent) -> Void = { _ in }
    ) -> IngestBlockingResult {
        ingestBlockingWithOutcome(
            event: event,
            waitTimeout: waitTimeout,
            onAcceptedOnMainActor: onAcceptedOnMainActor,
            onAccepted: onAccepted
        ).result
    }

    /// For positive-timeout ingress, returns the authoritative accepted event
    /// from the same synchronized acceptance that supplies the blocking result.
    func ingestBlockingWithOutcome(
        event: WorkstreamEvent,
        waitTimeout: TimeInterval,
        onAcceptedOnMainActor: @escaping @MainActor @Sendable (WorkstreamEvent) -> Void = { _ in },
        onAccepted: @escaping @Sendable (WorkstreamEvent) -> Void = { _ in }
    ) -> IngestBlockingOutcome {
        if waitTimeout <= 0 {
            guard enqueueZeroWaitAcceptance(
                event,
                onAcceptedOnMainActor: onAcceptedOnMainActor,
                onAccepted: onAccepted
            ) else {
                return IngestBlockingOutcome(result: .unavailable, authoritativeEvent: nil)
            }
            return IngestBlockingOutcome(
                result: .acknowledged(itemId: nil),
                authoritativeEvent: nil
            )
        }
        let deliveryDeadline: ContinuousClock.Instant = .now + .seconds(waitTimeout)
        guard let requestId = event.requestId else {
            let acceptance = performAcceptedEventDelivery(
                for: [event],
                timeout: waitTimeout
            ) { result in
                let acceptedEvent: WorkstreamEvent? = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard let acceptance = result.commit({
                            guard ContinuousClock.now < deliveryDeadline else {
                                return FeedEventAcceptance.unavailable
                            }
                            return FeedCoordinator.shared.acceptOnMainActor(event)
                        }) else {
                            return nil
                        }
                        guard case .accepted(let acceptedEvent, _) = acceptance else {
                            return nil
                        }
                        onAcceptedOnMainActor(acceptedEvent)
                        return acceptedEvent
                    }
                }
                if let acceptedEvent {
                    onAccepted(acceptedEvent)
                }
            }
            guard let acceptance else {
                return IngestBlockingOutcome(result: .unavailable, authoritativeEvent: nil)
            }
            switch acceptance {
            case .accepted(let acceptedEvent, let itemId):
                return IngestBlockingOutcome(
                    result: .acknowledged(itemId: itemId),
                    authoritativeEvent: acceptedEvent
                )
            case .notFound:
                return IngestBlockingOutcome(result: .notFound, authoritativeEvent: nil)
            case .unavailable:
                return IngestBlockingOutcome(result: .unavailable, authoritativeEvent: nil)
            }
        }

        // Resolve before entering the global delivery lane so hook-session disk
        // I/O for one agent cannot stall otherwise unrelated Feed ingress.
        let resolvedAttentionTarget = Self.isBlockingDecisionEvent(event.hookEventName)
            ? Self.resolveAttentionTarget(event: event)
            : nil
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = PendingWaiter(semaphore: semaphore)

        let acceptance = performAcceptedEventDelivery(
            for: [event],
            timeout: waitTimeout
        ) { result in
            let acceptedEvent: WorkstreamEvent? = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let acceptance = result.commit({
                        guard ContinuousClock.now < deliveryDeadline else {
                            return FeedEventAcceptance.unavailable
                        }
                        // Register in the commit boundary before the store sees
                        // the event, so a fast reply cannot slip through.
                        FeedCoordinator.shared.waiterLock.lock()
                        FeedCoordinator.shared.waiters[requestId] = waiter
                        FeedCoordinator.shared.waiterLock.unlock()
                        return FeedCoordinator.shared.acceptOnMainActor(event)
                    }) else {
                        return nil
                    }
                    guard case .accepted(let acceptedEvent, _) = acceptance else {
                        return nil
                    }
                    // Surface in-app attention (needs-input status + workspace
                    // elevation) for the blocking decision. This fires
                    // regardless of app focus, unlike the desktop banner below,
                    // so the pending decision is visible in the sidebar even
                    // while the user is in another workspace of the same window.
                    // The target is resolved before entering this main-thread
                    // section so hook-session disk I/O never extends the UI
                    // critical section.
                    //
                    // Publication intentionally follows the committed mutation:
                    // a stalled callback cannot hold the synchronous result lock
                    // past the socket caller's deadline.
                    let liveOwnerId = acceptedEvent.workspaceId.flatMap {
                        UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    let liveSurfaceId = acceptedEvent.surfaceId.flatMap {
                        UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    let attentionTarget = liveOwnerId.map {
                        (ownerId: $0, surfaceId: liveSurfaceId)
                    } ?? resolvedAttentionTarget
                    let attentionTabManager = attentionTarget.flatMap {
                        AppDelegate.shared?.tabManagerFor(tabId: $0.ownerId)
                            ?? AppDelegate.shared?.tabManagerFor(windowId: $0.ownerId)
                    }
                    if let target = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                        event: acceptedEvent,
                        resolved: attentionTarget,
                        tabManager: attentionTabManager
                    ) {
                        var shouldConcludeImmediately = false
                        FeedCoordinator.shared.waiterLock.lock()
                        if let registeredWaiter = FeedCoordinator.shared.waiters[requestId],
                           registeredWaiter.decision == nil {
                            registeredWaiter.attentionTarget = target
                        } else {
                            // A reply raced attention publication. Its reply path
                            // could not observe this target, so balance it here.
                            shouldConcludeImmediately = true
                        }
                        FeedCoordinator.shared.waiterLock.unlock()
                        if shouldConcludeImmediately {
                            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
                        }
                    }
                    onAcceptedOnMainActor(acceptedEvent)
                    #if DEBUG
                    FeedCoordinatorTestHooks.afterBlockingEventIngested?(acceptedEvent, requestId)
                    #endif
                    return acceptedEvent
                }
            }
            if let acceptedEvent {
                onAccepted(acceptedEvent)
            }
        }
        guard let acceptance else {
            waiterLock.lock()
            let attentionTarget = waiters.removeValue(forKey: requestId)?.attentionTarget
            waiterLock.unlock()
            concludeAttentionOnMain(attentionTarget)
            cancelNotification(requestId: requestId)
            return IngestBlockingOutcome(result: .unavailable, authoritativeEvent: nil)
        }

        let accepted: (event: WorkstreamEvent, itemId: UUID)
        switch acceptance {
        case .accepted(let event, let itemId):
            accepted = (event, itemId)
        case .notFound:
            waiterLock.lock()
            waiters.removeValue(forKey: requestId)
            waiterLock.unlock()
            return IngestBlockingOutcome(result: .notFound, authoritativeEvent: nil)
        case .unavailable:
            waiterLock.lock()
            waiters.removeValue(forKey: requestId)
            waiterLock.unlock()
            return IngestBlockingOutcome(result: .unavailable, authoritativeEvent: nil)
        }
        // If this is a blocking actionable event and the app window isn't
        // focused, post a native notification banner with inline action
        // buttons so the user can respond without switching windows.
        postNotificationIfStillAwaiting(event: accepted.event, requestId: requestId)

        let remainingDecisionTimeout = Self.remainingIngressTime(until: deliveryDeadline)
        let deadline: DispatchTime = .now() + max(remainingDecisionTimeout, 0)
        let waitResult = semaphore.wait(timeout: deadline)

        waiterLock.lock()
        let w = waiters.removeValue(forKey: requestId)
        waiterLock.unlock()

        switch waitResult {
        case .success:
            if let decision = w?.decision {
                // `deliverReply` concludes the attention overlay on resolve.
                return IngestBlockingOutcome(
                    result: .resolved(itemId: accepted.itemId, decision: decision),
                    authoritativeEvent: accepted.event
                )
            }
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(w?.attentionTarget)
            expireTimedOutItem(accepted.itemId)
            return IngestBlockingOutcome(
                result: .timedOut(itemId: accepted.itemId),
                authoritativeEvent: accepted.event
            )
        case .timedOut:
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(w?.attentionTarget)
            expireTimedOutItem(accepted.itemId)
            return IngestBlockingOutcome(
                result: .timedOut(itemId: accepted.itemId),
                authoritativeEvent: accepted.event
            )
        }
    }

    private func enqueueZeroWaitAcceptance(
        _ event: WorkstreamEvent,
        onAcceptedOnMainActor: @escaping @MainActor @Sendable (WorkstreamEvent) -> Void,
        onAccepted: @escaping @Sendable (WorkstreamEvent) -> Void
    ) -> Bool {
        return feedIngressDeliveryLane.enqueueZeroWait(
            metadata: Self.ingressMetadata(
                for: [event],
                importance: event.zeroWaitFeedIngressImportance
            )
        ) { result in
            let acceptedEvent: WorkstreamEvent? = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let accept: () -> WorkstreamEvent? = {
                        guard case .accepted(let event, _) = FeedCoordinator.shared.acceptOnMainActor(event) else {
                            return nil
                        }
                        return event
                    }
                    guard let result else {
                        let acceptedEvent = accept()
                        if let acceptedEvent {
                            onAcceptedOnMainActor(acceptedEvent)
                        }
                        return acceptedEvent
                    }
                    var committedEvent: WorkstreamEvent?
                    guard result.commit({
                        committedEvent = accept()
                    }) != nil else {
                        return nil
                    }
                    if let committedEvent {
                        onAcceptedOnMainActor(committedEvent)
                    }
                    return committedEvent
                }
            }
            if let acceptedEvent {
                onAccepted(acceptedEvent)
            }
        }
    }

    private static func ingressMetadata(
        for events: [WorkstreamEvent],
        importance: FeedIngressDeliveryImportance
    ) -> FeedIngressDeliveryMetadata {
        FeedIngressDeliveryMetadata(
            keys: Set(events.map(\.feedIngressDeliveryKey)),
            importance: importance
        )
    }

    private static func remainingIngressTime(
        until deadline: ContinuousClock.Instant
    ) -> TimeInterval {
        let components = ContinuousClock.now.duration(to: deadline).components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Concludes an attention overlay (if any) on the main actor, hopping if
    /// called from the socket worker thread.
    private func concludeAttentionOnMain(_ target: FeedAttentionTarget?) {
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

    enum IngestBlockingResult: Sendable {
        case acknowledged(itemId: UUID?)
        case resolved(itemId: UUID?, decision: WorkstreamDecision)
        case timedOut(itemId: UUID?)
        case notFound
        case unavailable
    }

    struct IngestBlockingOutcome: Sendable {
        let result: IngestBlockingResult
        let authoritativeEvent: WorkstreamEvent?
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

    /// Returns the Feed-owned status/lifecycle slot for one agent source.
    /// Keeping this transient overlay separate from the agent's own slot makes
    /// concurrent hook updates and overlapping Feed decisions independent.
    static func attentionStatusKey(forSource source: String) -> String {
        "cmux.feed.attention:\(lifecycleStatusKey(forSource: source))"
    }

    /// The localized "Needs input" sidebar status the overlay sets.
    static var needsInputStatusValue: String {
        String(localized: "feed.status.needsInput", defaultValue: "Needs input")
    }

    /// Surfaces in-app attention for a blocking feed decision: flips the exact
    /// panel owner's Feed-owned lifecycle to `.needsInput`, sets its
    /// Feed-owned "Needs input" status, and elevates workspace owners when
    /// *Reorder on Notification* is enabled. The agent's own lifecycle and
    /// status slots remain authoritative and untouched. Window-Dock owners
    /// retain their own runtime instead of being reinterpreted as workspaces.
    ///
    /// This is the convergence point the PreToolUse→PermissionRequest
    /// migration left behind: the `feed.push` bridge ingested the card and
    /// (when inactive) posted a banner, but never drove the same in-app
    /// attention path the `cmux hooks <agent> notification` hook uses. Doing
    /// it here — once, for every blocking decision — keeps a new event type
    /// from silently swallowing.
    ///
    /// Process-level AppKit attention is intentionally excluded: Stage Manager
    /// can promote the entire cmux window set even though no user action targeted
    /// cmux. The lifecycle and status mutations below are the attention surface.
    ///
    /// The overlay is cleared by ``concludeBlockingDecisionAttention(_:)``
    /// when the decision resolves or times out. Clearing is refcounted per
    /// ``FeedAttentionTarget`` so overlapping decisions on the same panel keep the
    /// badge lit until the last one concludes.
    ///
    /// - Parameter resolved: the target resolved off the main actor before UI
    ///   mutation, since hook-session lookup may read from disk.
    /// - Parameter tabManager: the window-local manager that owns a workspace
    ///   target or the window containing a Dock target.
    /// - Returns: the target to conclude once the decision ends, or `nil` if
    ///   nothing was surfaced (no resolvable owner).
    @MainActor
    func surfaceBlockingDecisionAttention(
        event: WorkstreamEvent,
        resolved: (ownerId: UUID, surfaceId: UUID?)?,
        tabManager: TabManager?
    ) -> FeedAttentionTarget? {
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

        let owner: ControlSidebarPanelOwner
        let panelId: UUID?
        let reorderWorkspaceId: UUID?
        if let dock = AppDelegate.shared?.existingWindowDock(forWindowId: resolved.ownerId) {
            guard let resolvedPanelId = resolved.surfaceId ?? dock.focusedPanelId,
                  dock.containsPanel(resolvedPanelId) else {
                #if DEBUG
                cmuxDebugLog(
                    "feed.attention.skip reason=missing-dock-surface session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) owner=\(resolved.ownerId.uuidString) surface=\(resolved.surfaceId?.uuidString ?? "nil") receivedAt=\(event.receivedAt.timeIntervalSince1970)"
                )
                #endif
                return nil
            }
            owner = .dock(dock)
            panelId = resolvedPanelId
            reorderWorkspaceId = nil
        } else {
            guard let tabManager,
                  let tab = tabManager.tabs.first(where: { $0.id == resolved.ownerId }) else {
                #if DEBUG
                cmuxDebugLog(
                    "feed.attention.skip reason=missing-owner session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) owner=\(resolved.ownerId.uuidString) receivedAt=\(event.receivedAt.timeIntervalSince1970)"
                )
                #endif
                return nil
            }
            reorderWorkspaceId = tab.id
            if let surfaceId = resolved.surfaceId,
               let target = tab.surfaceOwnershipTarget(for: surfaceId) {
                owner = .workspace(tab)
                panelId = target.containerPanelID
            } else if let surfaceId = resolved.surfaceId,
                      let dock = tab._dockSplit,
                      dock.containsPanel(surfaceId) {
                owner = .dock(dock)
                panelId = surfaceId
            } else {
                owner = .workspace(tab)
                panelId = resolved.surfaceId == nil ? tab.focusedPanelId : nil
            }
        }
        guard resolved.surfaceId == nil || panelId != nil else {
            #if DEBUG
            cmuxDebugLog(
                "feed.attention.skip reason=missing-surface session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) owner=\(resolved.ownerId.uuidString) surface=\(resolved.surfaceId?.uuidString ?? "nil") receivedAt=\(event.receivedAt.timeIntervalSince1970)"
            )
            #endif
            return nil
        }
        let statusKey = Self.attentionStatusKey(forSource: event.source)
        let target: FeedAttentionTarget
        if let panelId {
            target = .panel(id: panelId, statusKey: statusKey)
        } else {
            target = switch owner {
            case .workspace:
                .workspace(id: owner.id, statusKey: statusKey)
            case .dock:
                .dock(id: owner.id, statusKey: statusKey)
            }
        }
        let attentionState = pendingAttentionStates[target] ?? AttentionOverlayState(owner: owner)
        attentionState.fallbackOwner = owner
        attentionState.count += 1
        pendingAttentionStates[target] = attentionState

        // Needs-input lifecycle drives the sidebar badge + hibernation state.
        owner.setAgentLifecycle(key: statusKey, panelId: panelId, lifecycle: .needsInput)
        owner.setStatusEntry(SidebarStatusEntry(
            key: statusKey,
            value: Self.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF",
            timestamp: Date()
        ), key: statusKey, panelId: panelId)

        // Elevate the workspace so it floats to the top of the sidebar,
        // honoring the user's Reorder on Notification preference.
        if let reorderWorkspaceId,
           let tabManager,
           UserDefaultsSettingsClient(defaults: .standard).value(
               for: SettingCatalog().app.reorderOnNotification
           ) {
            tabManager.moveTabToTopForNotification(reorderWorkspaceId)
        }

        return target
    }

    /// Concludes a blocking decision's attention overlay. Decrements the
    /// per-target refcount and, when it reaches zero, clears the needs-input
    /// overlay. Feed owns a reserved lifecycle/status slot, so cleanup removes
    /// only that slot and never snapshots or restores the agent's concurrent
    /// running/idle/needs-input state.
    @MainActor
    func concludeBlockingDecisionAttention(_ target: FeedAttentionTarget) {
        guard let attentionState = pendingAttentionStates[target] else { return }
        if attentionState.count > 1 {
            attentionState.count -= 1
            return
        }
        pendingAttentionStates.removeValue(forKey: target)
        let owner = liveAttentionOwner(for: target, fallback: attentionState.fallbackOwner)

        // Lifecycle is per-panel, so clearing this Feed-owned slot is safe even
        // if another panel or the agent's own slot still needs input.
        if let panelId = target.panelId {
            owner.clearAgentLifecycle(key: target.statusKey, panelId: panelId)
        }

        // Workspace status is shared across panels (keyed only by statusKey),
        // so preserve it while another panel in that workspace is pending.
        // Dock runtime status is panel-scoped and can clear with its own target.
        let sharedWorkspaceStatusStillPending: Bool
        if case .workspace(let workspace) = owner {
            sharedWorkspaceStatusStillPending = pendingAttentionStates.contains {
                pendingTarget, pendingState in
                guard pendingTarget.statusKey == target.statusKey,
                      case .workspace(let pendingWorkspace) = liveAttentionOwner(
                          for: pendingTarget,
                          fallback: pendingState.fallbackOwner
                      ) else {
                    return false
                }
                return pendingWorkspace.id == workspace.id
            }
        } else {
            sharedWorkspaceStatusStillPending = false
        }
        if !sharedWorkspaceStatusStillPending {
            owner.clearStatusEntry(key: target.statusKey, panelId: target.panelId)
        }
    }

    /// Resolves a pending overlay's current mutation owner. A panel target is
    /// looked up at conclusion time so transfer-carried runtime is cleared at
    /// its destination; the retained owner is only a best-effort fallback for
    /// a panel between owners or an owner-scoped target that has disappeared.
    @MainActor
    private func liveAttentionOwner(
        for target: FeedAttentionTarget,
        fallback: ControlSidebarPanelOwner
    ) -> ControlSidebarPanelOwner {
        guard let appDelegate = AppDelegate.shared else { return fallback }
        switch target {
        case .panel(let panelId, _):
            switch fallback {
            case .workspace(let workspace):
                if let registeredWorkspace = appDelegate
                    .tabManagerFor(tabId: workspace.id)?
                    .workspacesById[workspace.id],
                   registeredWorkspace === workspace,
                   workspace.surfaceOwnershipTarget(for: panelId) != nil {
                    return fallback
                }
            case .dock(let dock):
                if DockSplitStore.liveStores.contains(where: {
                    $0 === dock && $0.containsPanel(panelId)
                }) {
                    return fallback
                }
            }
            if let dock = DockSplitStore.liveStore(containingPanel: panelId) {
                return .dock(dock)
            }
            if let workspace = appDelegate.workspaceContainingPanel(
                panelId: panelId,
                preferredWorkspaceId: fallback.id
            )?.workspace {
                return .workspace(workspace)
            }
        case .workspace(let ownerId, _):
            if let manager = appDelegate.tabManagerFor(tabId: ownerId),
               let workspace = manager.workspacesById[ownerId] {
                return .workspace(workspace)
            }
        case .dock(let ownerId, _):
            if let dock = DockSplitStore.liveStores.first(where: {
                $0.workspaceId == ownerId
            }) {
                return .dock(dock)
            }
        }
        return fallback
    }

    /// Resolves the `(owner, surface)` an attention overlay should target. The
    /// wire `workspace_id` is the owning workspace UUID for workspace surfaces
    /// and the owning window UUID for window-Dock surfaces. Prefer that live
    /// value so a stale hook-session map cannot redirect attention; fall back
    /// to the session store only when the event omits a parseable owner. A
    /// stored surface is trusted only when its stored owner also matches.
    private static func resolveAttentionTarget(
        event: WorkstreamEvent
    ) -> (ownerId: UUID, surfaceId: UUID?)? {
        let sessionMatch: (ownerId: UUID, surfaceId: UUID?)? = {
            guard let parsed = FeedJumpResolver.parse(event.sessionId),
                  let resolved = FeedJumpResolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId),
                  let workspaceId = UUID(uuidString: resolved.workspaceId)
            else { return nil }
            return (workspaceId, UUID(uuidString: resolved.surfaceId))
        }()

        let eventOwnerId = event.workspaceId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let ownerId = eventOwnerId ?? sessionMatch?.ownerId else {
            return nil
        }
        // Only trust the session store's surface if it belongs to the owner
        // we're actually targeting.
        let surfaceId = (sessionMatch?.ownerId == ownerId) ? sessionMatch?.surfaceId : nil
        return (ownerId, surfaceId)
    }

}

@MainActor
private final class AttentionOverlayState {
    var count: Int
    var fallbackOwner: ControlSidebarPanelOwner

    init(owner: ControlSidebarPanelOwner) {
        self.count = 0
        self.fallbackOwner = owner
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
    var attentionTarget: FeedAttentionTarget?

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }
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
    /// surfacing (needs-input status + elevation). When set, the
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
                categoryId = Self.inlineQuestionOptions(for: event) == nil
                    ? "CMUXFeedQuestion"
                    : "CMUXFeedQuestion.\(requestId)"
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

    private static func inlineQuestionOptions(
        for event: WorkstreamEvent
    ) -> [WorkstreamQuestionOption]? {
        let questions = WorkstreamQuestionPrompt.parse(toolInputJSON: event.toolInputJSON)
        guard questions.count == 1,
              let question = questions.first,
              !question.multiSelect,
              (1...4).contains(question.options.count) else { return nil }
        return question.options
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
        if let options = Self.inlineQuestionOptions(for: event) {
            content.userInfo["questionOptionIds"] = options.map(\.id)
        }

        let request = UNNotificationRequest(
            identifier: "feed.\(requestId)",
            content: content,
            trigger: nil
        )

        let center = resolvedUserNotificationCenter
        Task { @MainActor [weak self] in
            let statusResult = await center.authorizationStatus()
            guard let self, self.isAwaitingDecision(requestId: requestId) else { return }
            let status: UserNotificationAuthorizationStatus
            switch statusResult {
            case .success(let value):
                status = value
            case .failure:
                // The notification daemon is unresponsive; treat authorization
                // as unknown and stay audible (fail-open) via local fallback.
                self.runFallbackEffectsIfStillAwaiting(
                    requestId: requestId,
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    effects: TerminalNotificationStore.fallbackEffects(
                        effects,
                        authorizationState: .unknown
                    ),
                    runCommand: false
                )
                return
            }
            switch status {
            case .authorized, .provisional:
                self.registerQuestionCategoryAndAddIfStillAwaiting(
                    request: request,
                    event: event,
                    requestId: requestId,
                    effects: effects
                )
            case .notDetermined:
                let authorization = await center.requestAuthorization(options: [.alert, .sound])
                guard self.isAwaitingDecision(requestId: requestId) else { return }
                if case .success(true) = authorization {
                    self.registerQuestionCategoryAndAddIfStillAwaiting(
                        request: request,
                        event: event,
                        requestId: requestId,
                        effects: effects
                    )
                } else {
                    // A non-grant without an error is the user declining
                    // the prompt just now: honor the fresh denial on this
                    // very notification. A request failure is not a user
                    // decision, so the fallback stays audible (fail-open).
                    let requestFailed: Bool
                    if case .failure = authorization {
                        requestFailed = true
                    } else {
                        requestFailed = false
                    }
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
            case .denied, .ephemeral, .unknown:
                self.runFallbackEffectsIfStillAwaiting(
                    requestId: requestId,
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    effects: TerminalNotificationStore.fallbackEffects(
                        effects,
                        authorizationState: TerminalNotificationStore.authorizationState(from: status)
                    ),
                    runCommand: false
                )
            }
        }
    }

    @MainActor
    func registerQuestionCategoryAndAddIfStillAwaiting(
        request: UNNotificationRequest,
        event: WorkstreamEvent,
        requestId: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard request.content.categoryIdentifier.hasPrefix("CMUXFeedQuestion."),
              let options = Self.inlineQuestionOptions(for: event) else {
            addNotificationIfStillAwaiting(
                request: request,
                requestId: requestId,
                effects: effects
            )
            return
        }

        let optionActions = options.enumerated().map { index, option in
            UNNotificationAction(
                identifier: "feed.question.option.\(index)",
                title: option.label
            )
        }
        var actions = optionActions
        if options.count <= 3 {
            actions.append(UNTextInputNotificationAction(
                identifier: "feed.question.other",
                title: String(
                    localized: "feed.notification.question.other",
                    defaultValue: "Other…"
                ),
                options: [],
                textInputButtonTitle: String(
                    localized: "terminal.notification.action.replySend",
                    defaultValue: "Send"
                ),
                textInputPlaceholder: String(
                    localized: "terminal.notification.action.replyPlaceholder",
                    defaultValue: "Message the agent…"
                )
            ))
        }
        let minted = UNNotificationCategory(
            identifier: request.content.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        enqueueQuestionCategoryUpdate { [weak self] in
            guard let self, self.isAwaitingDecision(requestId: requestId) else { return }
            let center = self.resolvedUserNotificationCenter
            guard case .success(let current) = await center.notificationCategories() else {
                // Unresponsive daemon: deliver without inline options instead
                // of dropping — the plain banner still opens the Feed card.
                self.addNotificationIfStillAwaiting(
                    request: request,
                    requestId: requestId,
                    effects: effects
                )
                return
            }
            let liveCategoryIds = self.liveWaiterRequestIds().map { "CMUXFeedQuestion.\($0)" }
            var categories = Set(current.filter { category in
                !category.identifier.hasPrefix("CMUXFeedQuestion.")
                    || liveCategoryIds.contains(category.identifier)
            })
            categories.insert(minted)
            _ = await center.setNotificationCategories(categories)
            self.addNotificationIfStillAwaiting(
                request: request,
                requestId: requestId,
                effects: effects
            )
        }
    }

    /// Appends one `CMUXFeedQuestion.` category round trip to the serialized
    /// chain (see `questionCategoryUpdates`). Order between distinct requests
    /// is irrelevant — a mint whose waiter already resolved aborts on its
    /// `isAwaitingDecision` guard, and every update prunes dead categories —
    /// but no two round trips may interleave.
    @MainActor
    private func enqueueQuestionCategoryUpdate(_ update: @escaping @MainActor () async -> Void) {
        let previous = questionCategoryUpdates
        questionCategoryUpdates = Task { @MainActor in
            await previous?.value
            await update()
        }
    }

    func liveWaiterRequestIds() -> Set<String> {
        waiterLock.lock()
        defer { waiterLock.unlock() }
        return Set(waiters.compactMap { requestId, waiter in
            waiter.decision == nil ? requestId : nil
        })
    }

    @MainActor
    func addNotificationIfStillAwaiting(
        request: UNNotificationRequest,
        requestId: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard isAwaitingDecision(requestId: requestId) else { return }
        let title = request.content.title
        let subtitle = request.content.subtitle
        let body = request.content.body
        let center = resolvedUserNotificationCenter
        Task { @MainActor [weak self] in
            let result = await center.add(request)
            guard let self else { return }
            if !self.isAwaitingDecision(requestId: requestId) {
                self.cancelNotification(requestId: requestId)
                return
            }
            if case .failure = result {
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = self.resolvedUserNotificationCenter
            _ = await center.removePendingNotificationRequests(withIdentifiers: [identifier])
            _ = await center.removeDeliveredNotifications(withIdentifiers: [identifier])
            let categoryId = "CMUXFeedQuestion.\(requestId)"
            self.enqueueQuestionCategoryUpdate {
                guard case .success(let current) = await center.notificationCategories() else { return }
                let categories = Set(current.filter { $0.identifier != categoryId })
                _ = await center.setNotificationCategories(categories)
            }
        }
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
        case .notFound:
            return ["status": "not_found"]
        case .unavailable:
            return ["status": "unavailable"]
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
