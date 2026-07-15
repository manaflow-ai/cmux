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
// Safety: mutable UI state is MainActor-isolated, while the only worker-thread
// state lives in `FeedBlockingWaiterRegistry` behind its documented lock.
final class FeedCoordinator: @unchecked Sendable {
    static let shared = FeedCoordinator()
    static let storeInstalledNotification = Notification.Name("cmux.feed.storeInstalled")

    // The store runs on the main actor. The coordinator is not isolated,
    // so it hops to main explicitly when touching the store.
    @MainActor private(set) var store: WorkstreamStore!

    private let waiterRegistry = FeedBlockingWaiterRegistry()

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
    @MainActor var pendingAttentionStates: [AttentionTarget: AttentionOverlayState] = [:]

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
            Task { @MainActor in
                FeedCoordinator.shared.store.ingest(event)
                if let ppid = event.ppid, ppid > 0 {
                    FeedCoordinator.shared.armPidWatcher(ppid: ppid)
                }
            }
            return .acknowledged(itemId: nil)
        }

        // Register the waiter before the store sees the event so a very
        // fast reply can't slip through.
        let semaphore = waiterRegistry.register(requestID: requestId)

        // Hop to main to actually insert the item + install the
        // kqueue watcher for the agent's PID. The watcher handler
        // caps the pending lifetime to the agent process lifetime
        // — no polling, no leaked cards when the agent is killed.
        let resolvedAttentionTarget = Self.isBlockingDecisionEvent(event.hookEventName)
            ? Self.resolveAttentionTarget(event: event)
            : nil
        let itemID: UUID? = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                FeedCoordinator.shared.store.ingest(event)
                let itemID = FeedCoordinator.shared.store.items.last?.id
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
                    FeedCoordinator.shared.waiterRegistry.setAttentionTarget(
                        target,
                        requestID: requestId
                    )
                }
                #if DEBUG
                FeedCoordinatorTestHooks.afterBlockingEventIngested?(event, requestId)
                #endif
                return itemID
            }
        }

        // If this is a blocking actionable event and the app window isn't
        // focused, post a native notification banner with inline action
        // buttons so the user can respond without switching windows.
        postNotificationIfStillAwaiting(event: event, requestId: requestId)

        let deadline: DispatchTime = .now() + waitTimeout
        let waitResult = semaphore.wait(timeout: deadline)

        let waiter = waiterRegistry.remove(requestID: requestId)

        switch waitResult {
        case .success:
            if let decision = waiter?.decision {
                // `deliverReply` concludes the attention overlay on resolve.
                return .resolved(itemId: itemID, decision: decision)
            }
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(waiter?.attentionTarget)
            expireTimedOutItem(itemID)
            return .timedOut(itemId: itemID)
        case .timedOut:
            cancelNotification(requestId: requestId)
            concludeAttentionOnMain(waiter?.attentionTarget)
            expireTimedOutItem(itemID)
            return .timedOut(itemId: itemID)
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
            Task { @MainActor in conclude() }
        }
    }

    /// Called by the `feed.*.reply` handlers. Marks the corresponding
    /// item resolved on the main-actor store and wakes any waiter.
    func deliverReply(requestId: String, decision: WorkstreamDecision) {
        let attentionTarget = waiterRegistry.deliver(decision, requestID: requestId)

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
            Task { @MainActor in resolve() }
        }

        cancelNotification(requestId: requestId)
    }

    func isAwaitingDecision(requestId: String) -> Bool {
        waiterRegistry.isAwaitingDecision(requestID: requestId)
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
