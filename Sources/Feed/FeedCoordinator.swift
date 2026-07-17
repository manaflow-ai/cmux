import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSettings
import CmuxSidebar
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
// Safety: mutable UI state is MainActor-isolated, while the only worker-thread
// state lives in `FeedBlockingWaiterRegistry` behind its documented lock.
final class FeedCoordinator: @unchecked Sendable {
  static let shared = FeedCoordinator()
  static let storeInstalledNotification = Notification.Name("cmux.feed.storeInstalled")

  // The store runs on the main actor. The coordinator is not isolated,
  // so it hops to main explicitly when touching the store.
  @MainActor private(set) var store: WorkstreamStore!

  private let waiterRegistry = FeedBlockingWaiterRegistry()
  let notificationHookCache = CmuxNotificationHookCache()
  let jumpResolver: FeedJumpResolver
  let socketEncoder = FeedSocketEncoder()
  private let timeoutClock: ContinuousClock

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

  private init(
    jumpResolver: FeedJumpResolver = FeedJumpResolver(),
    timeoutClock: ContinuousClock = ContinuousClock()
  ) {
    self.jumpResolver = jumpResolver
    self.timeoutClock = timeoutClock
  }

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
  ) async -> IngestBlockingResult {
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
    guard let decisions = await waiterRegistry.register(requestID: requestId) else {
      return .timedOut(itemId: nil)
    }

    // Hop to main to actually insert the item + install the
    // kqueue watcher for the agent's PID. The watcher handler
    // caps the pending lifetime to the agent process lifetime
    // — no polling, no leaked cards when the agent is killed.
    let resolvedAttentionTarget =
      Self.isBlockingDecisionEvent(event.hookEventName)
      ? resolveAttentionTarget(event: event)
      : nil
    let ingestResult: (itemID: UUID?, attentionTarget: AttentionTarget?) = await MainActor.run {
      self.store.ingest(event)
      let itemID = self.store.items.last?.id
      if let ppid = event.ppid, ppid > 0 {
        self.armPidWatcher(ppid: ppid)
      }
      let attentionTarget = self.surfaceBlockingDecisionAttention(
        event: event,
        resolved: resolvedAttentionTarget
      )
      return (itemID, attentionTarget)
    }
    let registration = await waiterRegistry.recordIngest(
      itemID: ingestResult.itemID,
      attentionTarget: ingestResult.attentionTarget,
      requestID: requestId
    )
    guard registration.registered else {
      await MainActor.run {
        self.concludeBlockingDecisionAttentionIfPresent(ingestResult.attentionTarget)
        if let itemID = ingestResult.itemID {
          self.store?.markExpired(itemID)
        }
      }
      return .timedOut(itemId: ingestResult.itemID)
    }
    if let earlyDecision = registration.earlyDecision {
      _ = await waiterRegistry.remove(requestID: requestId)
      await MainActor.run {
        if let itemID = ingestResult.itemID {
          self.store?.markResolved(itemID, decision: earlyDecision)
        }
        self.concludeBlockingDecisionAttentionIfPresent(ingestResult.attentionTarget)
      }
      return .resolved(itemId: ingestResult.itemID, decision: earlyDecision)
    }

    // If this blocking actionable event is still pending and the app is
    // inactive, offer the same decision through a native banner.
    postNotificationIfStillAwaiting(event: event, requestId: requestId)

    let deliveredDecision = await withTaskGroup(of: WorkstreamDecision?.self) { group in
      group.addTask {
        for await decision in decisions {
          return decision
        }
        return nil
      }
      group.addTask {
        try? await self.timeoutClock.sleep(for: .seconds(waitTimeout))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }

    let waiter = await waiterRegistry.remove(requestID: requestId)

    if let decision = deliveredDecision ?? waiter?.decision {
      // A decision that wins at the timeout boundary remains terminal
      // even when Dispatch reports the timeout result first.
      return .resolved(itemId: waiter?.itemID, decision: decision)
    }

    cancelNotification(requestId: requestId)
    concludeAttentionOnMain(waiter?.attentionTarget)
    expireTimedOutItem(waiter?.itemID)
    return .timedOut(itemId: waiter?.itemID)
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

  @MainActor
  private func concludeBlockingDecisionAttentionIfPresent(_ target: AttentionTarget?) {
    guard let target else { return }
    concludeBlockingDecisionAttention(target)
  }

  /// Called by the `feed.*.reply` handlers. Marks the corresponding
  /// item resolved on the main-actor store and wakes any waiter.
  @discardableResult
  func deliverReply(requestId: String, decision: WorkstreamDecision) async -> Bool {
    let delivery = await waiterRegistry.deliver(
      decision,
      requestID: requestId
    )
    guard delivery.accepted else {
      return false
    }

    // The user decided: conclude the needs-input overlay so the agent's
    // running/idle state shows through (refcounted so an overlapping
    // decision on the same panel keeps it lit until it too concludes).
    concludeAttentionOnMain(delivery.attentionTarget)

    await MainActor.run {
      guard let store, let itemID = delivery.itemID else { return }
      store.markResolved(itemID, decision: decision)
    }

    cancelNotification(requestId: requestId)
    return true
  }

  func isAwaitingDecision(requestId: String) async -> Bool {
    await waiterRegistry.isAwaitingDecision(requestID: requestId)
  }

  private func expireTimedOutItem(_ itemId: UUID?) {
    guard let itemId else { return }
    Task { @MainActor [weak self] in
      self?.store?.markExpired(itemId)
    }
  }

  enum IngestBlockingResult: Sendable {
    case acknowledged(itemId: UUID?)
    case resolved(itemId: UUID?, decision: WorkstreamDecision)
    case timedOut(itemId: UUID?)
  }
}
