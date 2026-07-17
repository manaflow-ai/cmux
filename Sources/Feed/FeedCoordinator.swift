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

  // The store runs on the main actor. The coordinator is not isolated,
  // so it hops to main explicitly when touching the store.
  @MainActor private(set) var store: WorkstreamStore!
  @MainActor private(set) lazy var presentationStore = FeedPresentationStore()

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
    presentationStore.install(source: store)
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
    guard !Task.isCancelled else { return .timedOut(itemId: nil) }
    guard let requestId = event.requestId, waitTimeout > 0 else {
      let itemID = await MainActor.run { () -> UUID? in
        guard !Task.isCancelled else { return nil }
        self.store.ingest(event)
        if let ppid = event.ppid, ppid > 0 {
          self.armPidWatcher(ppid: ppid)
        }
        return self.store.items.last?.id
      }
      return Task.isCancelled ? .timedOut(itemId: itemID) : .acknowledged(itemId: itemID)
    }

    // Register the waiter before the store sees the event so a very
    // fast reply can't slip through.
    guard let decisions = await waiterRegistry.register(requestID: requestId) else {
      return .timedOut(itemId: nil)
    }
    guard !Task.isCancelled else {
      _ = await waiterRegistry.remove(requestID: requestId)
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
      guard !Task.isCancelled else { return (nil, nil) }
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
    guard !Task.isCancelled else {
      await cancelIngest(
        requestID: requestId,
        itemID: ingestResult.itemID,
        attentionTarget: ingestResult.attentionTarget
      )
      return .timedOut(itemId: ingestResult.itemID)
    }
    let registration = await waiterRegistry.recordIngest(
      itemID: ingestResult.itemID,
      attentionTarget: ingestResult.attentionTarget,
      requestID: requestId
    )
    guard !Task.isCancelled else {
      await cancelIngest(
        requestID: requestId,
        itemID: ingestResult.itemID,
        attentionTarget: ingestResult.attentionTarget
      )
      return .timedOut(itemId: ingestResult.itemID)
    }
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

    _ = await withTaskGroup(of: WorkstreamDecision?.self) { group in
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

    guard !Task.isCancelled else {
      let waiter = await waiterRegistry.expire(requestID: requestId)
      cancelNotification(requestId: requestId)
      await MainActor.run {
        self.concludeBlockingDecisionAttentionIfPresent(waiter?.attentionTarget)
        if let itemID = waiter?.itemID {
          self.store?.markExpired(itemID)
        }
      }
      await waiterRegistry.finalizeExpiration(requestID: requestId)
      return .timedOut(itemId: waiter?.itemID)
    }

    switch await waiterRegistry.completeAfterWait(requestID: requestId) {
    case .resolved(let waiter, let decision):
      return .resolved(itemId: waiter.itemID, decision: decision)
    case .timedOut(let waiter):
      cancelNotification(requestId: requestId)
      await MainActor.run {
        self.concludeBlockingDecisionAttentionIfPresent(waiter.attentionTarget)
        if let itemID = waiter.itemID {
          self.store?.markExpired(itemID)
        }
      }
      await waiterRegistry.finalizeExpiration(requestID: requestId)
      return .timedOut(itemId: waiter.itemID)
    case .missing:
      cancelNotification(requestId: requestId)
      return .timedOut(itemId: nil)
    }
  }

  private func cancelIngest(
    requestID: String,
    itemID: UUID?,
    attentionTarget: AttentionTarget?
  ) async {
    _ = await waiterRegistry.expire(requestID: requestID)
    cancelNotification(requestId: requestID)
    await MainActor.run {
      self.concludeBlockingDecisionAttentionIfPresent(attentionTarget)
      if let itemID {
        self.store?.markExpired(itemID)
      }
    }
    await waiterRegistry.finalizeExpiration(requestID: requestID)
  }

  /// Concludes an attention overlay (if any) on the main actor, hopping if
  /// called from the socket worker thread.
  private func concludeAttentionOnMain(_ target: AttentionTarget?) async {
    guard let target else { return }
    await MainActor.run {
      self.concludeBlockingDecisionAttention(target)
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

    // The user decided: conclude the needs-input overlay so the agent's
    // running/idle state shows through (refcounted so an overlapping
    // decision on the same panel keeps it lit until it too concludes).
    if delivery.accepted {
      await concludeAttentionOnMain(delivery.attentionTarget)
    }

    let resolvedItemID = await MainActor.run { () -> UUID? in
      guard let store else { return nil }
      let itemID: UUID?
      if delivery.accepted {
        itemID = delivery.itemID ?? Self.findPendingItemID(for: requestId, in: store.items)
      } else if !delivery.registered && !delivery.timedOut {
        itemID = Self.findPendingItemID(for: requestId, in: store.items)
      } else {
        itemID = nil
      }
      guard let itemID else { return nil }
      store.markResolved(itemID, decision: decision)
      return itemID
    }

    guard delivery.accepted || resolvedItemID != nil else { return false }
    cancelNotification(requestId: requestId)
    return true
  }

  private static func findPendingItemID(
    for requestID: String,
    in items: [WorkstreamItem]
  ) -> UUID? {
    items.reversed().first { item in
      guard item.status.isPending else { return false }
      switch item.payload {
      case .permissionRequest(let candidate, _, _, _),
           .exitPlan(let candidate, _, _),
           .question(let candidate, _):
        return candidate == requestID
      default:
        return false
      }
    }?.id
  }

  func isAwaitingDecision(requestId: String) async -> Bool {
    await waiterRegistry.isAwaitingDecision(requestID: requestId)
  }

  enum IngestBlockingResult: Sendable {
    case acknowledged(itemId: UUID?)
    case resolved(itemId: UUID?, decision: WorkstreamDecision)
    case timedOut(itemId: UUID?)
  }
}
