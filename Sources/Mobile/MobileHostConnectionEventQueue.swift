import CMUXMobileCore
import Foundation

/// Per-topic shedding policy for server-pushed mobile events.
///
/// "Droppable" topics are the streams a client can always recover without the
/// host replaying the exact dropped payload:
/// - `terminal.render_grid`: the producer is asked to re-emit a full frame for
///   every surface whose queued frame was shed
///   (``MobileTerminalRenderObserver/requestRenderGridFullResync(surfaceIDStrings:)``),
///   and the per-connection queue refuses further deltas for that surface until
///   the full frame arrives. The iOS client has no delta-continuity check, so a
///   silently dropped delta would corrupt its grid invisibly; the
///   poison-until-full rule makes a shed unobservable beyond one stale paint.
/// - `terminal.bytes`: chunks carry a byte-offset `seq`; the client detects the
///   gap on the next delivered chunk and requests a replay on its own.
/// - `terminal.updated` / `workspace.updated`: level-triggered pings. A newer
///   queued occurrence supersedes a shed one; when the shed ping was the LAST
///   one, the drain-repair signal re-emits it once the queue drains.
/// - `mobile.sync.delta`: revision-cursor stream (state sync v2). The client
///   already treats `from_rev` past its cursor as a gap and repairs with a
///   `mobile.sync.fetch`; after a shed, the drain-repair signal emits a
///   zero-record head marker so a gap is detected even when the shed delta was
///   the last one (see ``MobileHostShedRepairPlanner``).
/// - `notification.feed.changed`: revision-carrying invalidation ping; the
///   drain-repair signal re-emits the newest revision, and the client refetches
///   iff it missed one.
///
/// Every other topic keeps the close-on-overflow contract: those payloads
/// cannot be re-derived by the client, so tearing the connection down (the
/// client reconnects and re-syncs from authoritative state) is the only
/// lossless bound. Backpressure on a recoverable topic must NEVER close the
/// connection: the 2026-07 field incident showed a few seconds of QUIC write
/// stall filling this queue and killing a healthy session every ~2s
/// (`sendQueueOverflow`), forcing full phone redials mid path-flap.
enum MobileHostEventTopicPolicy {
    static let renderGridTopic = "terminal.render_grid"

    static func isDroppable(topic: String, coalesceKey: String?) -> Bool {
        switch topic {
        case renderGridTopic:
            // A render-grid event without a surface key cannot be resynced
            // per-surface, so it keeps the lossless close-on-overflow path.
            return coalesceKey != nil
        case "terminal.bytes", "terminal.updated", "workspace.updated",
             "mobile.sync.delta", "notification.feed.changed":
            return true
        default:
            return false
        }
    }

    /// Whether a shed on `topic` must be followed by one coalesced repair
    /// signal once the queue drains (``MobileHostConnectionEventQueue/takeShedRepairs()``).
    ///
    /// These are the level-triggered invalidations and cursor streams where
    /// the shed event may have been the last one: without a host-side repair
    /// the client would stay silently stale until an unrelated future event.
    /// `terminal.render_grid` repairs through the immediate
    /// poison-plus-full-resync path and `terminal.bytes` through the client's
    /// byte-offset gap detection, so neither needs a drain signal.
    static func needsDrainRepairSignal(topic: String) -> Bool {
        switch topic {
        case "terminal.updated", "workspace.updated",
             "mobile.sync.delta", "notification.feed.changed":
            return true
        default:
            return false
        }
    }
}

/// The coalesced backpressure outcome one drain cycle repairs: every topic
/// that lost at least one repair-signaled event since the last take, plus the
/// total number of events shed (all topics) for the diagnostic ring.
struct MobileHostEventQueueShedRepair: Equatable, Sendable {
    /// Topics that shed at least one event and need a repair signal
    /// (``MobileHostEventTopicPolicy/needsDrainRepairSignal(topic:)``).
    let topics: Set<String>
    /// Every event dropped under backpressure since the last take, including
    /// topics that repair through their own mechanism (render-grid resync,
    /// byte-gap replay).
    let shedEventCount: Int
}

/// Outcome of one synchronous admission attempt on a connection's event queue.
struct MobileHostEventEnqueueResult: Sendable {
    /// The event was appended to the bounded queue.
    let admitted: Bool
    /// The caller must start the (single) drain task for this connection.
    let startDrain: Bool
    /// A non-droppable event overflowed the bounded queue; the caller must
    /// close the connection — the lossless-topic contract.
    let shouldClose: Bool
    /// Surfaces whose queued render-grid frames were shed; the caller must ask
    /// the producer for a full-frame resync of each.
    let renderGridResyncSurfaceIDs: Set<String>
    /// Queue depth immediately after an admitted append.
    let depthAfterEnqueue: Int?

    static let rejected = MobileHostEventEnqueueResult(
        admitted: false,
        startDrain: false,
        shouldClose: false,
        renderGridResyncSurfaceIDs: [],
        depthAfterEnqueue: nil
    )
}

/// Bounded, synchronously-admitted mailbox between the event fan-out
/// (``MobileHostService/emitEvent(topic:payload:)``) and one connection's
/// drain loop.
///
/// This is the owner boundary for issue #8842: admission runs *before* any
/// per-connection work is scheduled, on the emitter's thread, against an
/// explicit bound — so the memory pinned per connection is O(capacity) no
/// matter how far emission runs ahead of a slow, paused, or half-dead
/// subscriber. The previous path spawned one unstructured Task per connection
/// per event, each retaining the full payload dictionary until the connection
/// actor reached its own bounded check, which left everything upstream of the
/// bound unbounded.
final class MobileHostConnectionEventQueue: @unchecked Sendable {
    struct QueuedEvent: Sendable {
        let topic: String
        let coalesceKey: String?
        let frame: Data
        let stateSeq: UInt64?
    }

    static let defaultMaximumEventCount = 256
    static let defaultMaximumByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount
        + MobileSyncFrameCodec.headerByteCount

    private let lock = NSLock()
    private let maximumEventCount: Int
    private let maximumByteCount: Int
    private var subscribedTopics: Set<String> = []
    private var queuedEvents: [QueuedEvent] = []
    private var queuedByteCount = 0
    private var drainActive = false
    private var isClosed = false
    /// Surfaces whose delta chain was broken by a shed frame. Only a
    /// full-frame render-grid event readmits the surface; deltas are refused so
    /// the client can never apply a delta whose predecessor was dropped.
    private var poisonedRenderGridSurfaceIDs: Set<String> = []
    /// Poisoned surfaces whose replacement full frame ALSO had to be dropped
    /// (queue full of non-droppable events). Re-requested once the drain frees
    /// room, so a fully stalled connection cannot spin the producer.
    private var resyncAfterDrainSurfaceIDs: Set<String> = []
    /// Queue depth at or below which pending shed repairs are released to the
    /// drain, so repair events land only once the transport is genuinely
    /// flowing again and are not immediately shed themselves.
    private let shedRepairLowWaterMark: Int
    /// Topics that shed at least one repair-signaled event since the last
    /// ``takeShedRepairs()``. Coalesced by construction: a topic appears once
    /// no matter how many of its events were dropped.
    private var shedRepairPendingTopics: Set<String> = []
    /// Every event dropped under backpressure since the last
    /// ``takeShedRepairs()`` (all topics), for the diagnostic ring.
    private var shedEventCountSinceRepairTake = 0

    init(
        maximumEventCount: Int = MobileHostConnectionEventQueue.defaultMaximumEventCount,
        maximumByteCount: Int = MobileHostConnectionEventQueue.defaultMaximumByteCount,
        shedRepairLowWaterMark: Int? = nil
    ) {
        self.maximumEventCount = maximumEventCount
        self.maximumByteCount = maximumByteCount
        self.shedRepairLowWaterMark = shedRepairLowWaterMark ?? max(1, maximumEventCount / 4)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedEvents.count
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedByteCount
    }

    /// Replaces the subscribed-topic snapshot used for synchronous admission.
    /// The owning connection calls this on subscribe/unsubscribe/close.
    func updateSubscribedTopics(_ topics: Set<String>) {
        lock.lock()
        subscribedTopics = topics
        lock.unlock()
    }

    func isSubscribed(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedTopics.contains(topic)
    }

    /// Synchronous bounded admission. Safe to call from any thread; never
    /// blocks on the network, the connection actor, or the runtime.
    func enqueue(
        topic: String,
        coalesceKey: String?,
        isFullRenderGridFrame: Bool,
        stateSeq: UInt64? = nil,
        frame: Data
    ) -> MobileHostEventEnqueueResult {
        lock.lock()
        guard !isClosed, subscribedTopics.contains(topic) else {
            lock.unlock()
            return .rejected
        }
        let isRenderGrid = topic == MobileHostEventTopicPolicy.renderGridTopic
        if isRenderGrid,
           let coalesceKey,
           !isFullRenderGridFrame,
           poisonedRenderGridSurfaceIDs.contains(coalesceKey) {
            // The surface's delta chain is already broken; only the pending
            // full frame may readmit it.
            lock.unlock()
            return .rejected
        }
        var resyncSurfaceIDs = Set<String>()
        if !hasRoomLocked(for: frame) {
            shedDroppableEventsLocked(for: frame, resyncSurfaceIDs: &resyncSurfaceIDs)
        }
        if isRenderGrid,
           let coalesceKey,
           !isFullRenderGridFrame,
           poisonedRenderGridSurfaceIDs.contains(coalesceKey) {
            // The shed pass just broke this surface's chain; this delta builds
            // on the shed frames, so it must not slip into the freed room.
            lock.unlock()
            return MobileHostEventEnqueueResult(
                admitted: false,
                startDrain: false,
                shouldClose: false,
                renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                depthAfterEnqueue: nil
            )
        }
        guard hasRoomLocked(for: frame) else {
            guard MobileHostEventTopicPolicy.isDroppable(topic: topic, coalesceKey: coalesceKey) else {
                lock.unlock()
                return MobileHostEventEnqueueResult(
                    admitted: false,
                    startDrain: false,
                    shouldClose: true,
                    renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                    depthAfterEnqueue: nil
                )
            }
            // The incoming droppable event itself is being dropped: it is a
            // shed like any other and joins the coalesced repair cycle.
            noteShedLocked(topic: topic)
            if isRenderGrid, let coalesceKey {
                if poisonedRenderGridSurfaceIDs.insert(coalesceKey).inserted {
                    resyncSurfaceIDs.insert(coalesceKey)
                } else if isFullRenderGridFrame {
                    // The replacement full frame itself could not be admitted;
                    // ask again once the drain makes room.
                    resyncAfterDrainSurfaceIDs.insert(coalesceKey)
                }
            }
            lock.unlock()
            return MobileHostEventEnqueueResult(
                admitted: false,
                startDrain: false,
                shouldClose: false,
                renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                depthAfterEnqueue: nil
            )
        }
        queuedEvents.append(
            QueuedEvent(
                topic: topic,
                coalesceKey: coalesceKey,
                frame: frame,
                stateSeq: stateSeq
            )
        )
        queuedByteCount += frame.count
        let depthAfterEnqueue = queuedEvents.count
        if isRenderGrid, isFullRenderGridFrame, let coalesceKey {
            poisonedRenderGridSurfaceIDs.remove(coalesceKey)
            resyncAfterDrainSurfaceIDs.remove(coalesceKey)
        }
        let startDrain = !drainActive
        if startDrain {
            drainActive = true
        }
        lock.unlock()
        return MobileHostEventEnqueueResult(
            admitted: true,
            startDrain: startDrain,
            shouldClose: false,
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: depthAfterEnqueue
        )
    }

    func dequeue() -> QueuedEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard !queuedEvents.isEmpty else { return nil }
        let event = queuedEvents.removeFirst()
        queuedByteCount -= event.frame.count
        return event
    }

    /// Called by the drain loop after `dequeue` returned nil. Returns true when
    /// events raced in and the loop must keep draining; otherwise the drain is
    /// marked finished so the next enqueue can claim a fresh one.
    func finishDrain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if queuedEvents.isEmpty || isClosed {
            drainActive = false
            return false
        }
        return true
    }

    /// Marks the drain inactive after an abnormal exit (close, lane
    /// negotiation, failed delivery) so a later enqueue can claim a fresh one.
    func abandonDrain() {
        lock.lock()
        drainActive = false
        lock.unlock()
    }

    /// Claims the drain when events are pending and none is running (used when
    /// independent-lane negotiation finishes and delivery may resume).
    func claimDrain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !drainActive, !queuedEvents.isEmpty else { return false }
        drainActive = true
        return true
    }

    /// Poisoned surfaces whose full-frame resync should be re-requested now
    /// that the drain has made progress.
    func takeResyncAfterDrainRequests() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !resyncAfterDrainSurfaceIDs.isEmpty else { return [] }
        let requests = resyncAfterDrainSurfaceIDs
        resyncAfterDrainSurfaceIDs.removeAll()
        return requests
    }

    /// Pending shed repairs, released only once the drain has pulled the
    /// queue down to the low-water mark so the repair events are not shed in
    /// turn. Taking resets the pending set and the shed count; a repair event
    /// that is itself shed later re-marks its topic, so the cycle self-heals.
    /// Returns `nil` while the queue is still congested or nothing was shed.
    func takeShedRepairs() -> MobileHostEventQueueShedRepair? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed,
              queuedEvents.count <= shedRepairLowWaterMark,
              shedEventCountSinceRepairTake > 0 else { return nil }
        let repairs = MobileHostEventQueueShedRepair(
            topics: shedRepairPendingTopics,
            shedEventCount: shedEventCountSinceRepairTake
        )
        shedRepairPendingTopics.removeAll()
        shedEventCountSinceRepairTake = 0
        return repairs
    }

    /// Rejects all future admissions and releases every queued payload.
    func close() {
        lock.lock()
        isClosed = true
        queuedEvents.removeAll(keepingCapacity: false)
        queuedByteCount = 0
        poisonedRenderGridSurfaceIDs.removeAll()
        resyncAfterDrainSurfaceIDs.removeAll()
        shedRepairPendingTopics.removeAll()
        shedEventCountSinceRepairTake = 0
        subscribedTopics.removeAll()
        lock.unlock()
    }

    private func hasRoomLocked(for frame: Data) -> Bool {
        queuedEvents.count < maximumEventCount
            && queuedByteCount + frame.count <= maximumByteCount
    }

    /// Records one backpressure drop for the repair cycle and the diagnostic
    /// shed count. Not called for poison-chain suppression (a refused
    /// render-grid delta whose surface is already awaiting its full frame):
    /// that drop was accounted for when the chain first broke.
    private func noteShedLocked(topic: String) {
        shedEventCountSinceRepairTake += 1
        if MobileHostEventTopicPolicy.needsDrainRepairSignal(topic: topic) {
            shedRepairPendingTopics.insert(topic)
        }
    }

    private func shedDroppableEventsLocked(
        for frame: Data,
        resyncSurfaceIDs: inout Set<String>
    ) {
        var index = 0
        while !hasRoomLocked(for: frame), index < queuedEvents.count {
            let event = queuedEvents[index]
            guard MobileHostEventTopicPolicy.isDroppable(
                topic: event.topic,
                coalesceKey: event.coalesceKey
            ) else {
                index += 1
                continue
            }
            queuedEvents.remove(at: index)
            queuedByteCount -= event.frame.count
            noteShedLocked(topic: event.topic)
            if event.topic == MobileHostEventTopicPolicy.renderGridTopic,
               let surfaceID = event.coalesceKey,
               poisonedRenderGridSurfaceIDs.insert(surfaceID).inserted {
                resyncSurfaceIDs.insert(surfaceID)
            }
        }
        // A shed frame breaks its surface's delta chain, so every remaining
        // queued render-grid frame for that surface — each builds on the shed
        // one — must go with it. The pending full-frame resync re-bases the
        // chain for the whole connection.
        guard !resyncSurfaceIDs.isEmpty else { return }
        var freedByteCount = 0
        var purgedEventCount = 0
        let brokenSurfaceIDs = resyncSurfaceIDs
        queuedEvents.removeAll { event in
            guard event.topic == MobileHostEventTopicPolicy.renderGridTopic,
                  let surfaceID = event.coalesceKey,
                  brokenSurfaceIDs.contains(surfaceID) else {
                return false
            }
            freedByteCount += event.frame.count
            purgedEventCount += 1
            return true
        }
        queuedByteCount -= freedByteCount
        shedEventCountSinceRepairTake += purgedEventCount
    }
}
