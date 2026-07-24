import CMUXMobileCore
import Foundation

/// Per-topic shedding policy for server-pushed mobile events.
///
/// "Droppable" topics are the refresh-class streams a client can always
/// recover without the host replaying the exact dropped payload:
/// - `terminal.render_grid`: the producer is asked to re-emit a full frame for
///   every surface whose queued frame was shed
///   (``MobileTerminalRenderObserver/requestRenderGridFullResync(surfaceIDStrings:)``),
///   and the per-connection queue refuses further deltas for that surface until
///   the full frame arrives. The iOS client has no delta-continuity check, so a
///   silently dropped delta would corrupt its grid invisibly; the
///   poison-until-full rule makes a shed unobservable beyond one stale paint.
/// - `terminal.bytes`: chunks carry a byte-offset `seq`; the client detects the
///   gap and requests a replay on its own.
/// - `terminal.updated` / `workspace.updated`: level-triggered pings; the newer
///   occurrence that forced the shed supersedes the shed one.
///
/// Every other topic keeps the close-on-overflow contract: those payloads
/// cannot be re-derived by the client, so tearing the connection down (the
/// client reconnects and re-syncs from authoritative state) is the only
/// lossless bound.
enum MobileHostEventTopicPolicy {
    static let renderGridTopic = "terminal.render_grid"

    static func isDroppable(topic: String, coalesceKey: String?) -> Bool {
        switch topic {
        case renderGridTopic:
            // A render-grid event without a surface key cannot be resynced
            // per-surface, so it keeps the lossless close-on-overflow path.
            return coalesceKey != nil
        case "terminal.bytes", "terminal.updated", "workspace.updated":
            return true
        default:
            return false
        }
    }
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

    static let rejected = MobileHostEventEnqueueResult(
        admitted: false,
        startDrain: false,
        shouldClose: false,
        renderGridResyncSurfaceIDs: []
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

    init(
        maximumEventCount: Int = MobileHostConnectionEventQueue.defaultMaximumEventCount,
        maximumByteCount: Int = MobileHostConnectionEventQueue.defaultMaximumByteCount
    ) {
        self.maximumEventCount = maximumEventCount
        self.maximumByteCount = maximumByteCount
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
                renderGridResyncSurfaceIDs: resyncSurfaceIDs
            )
        }
        guard hasRoomLocked(for: frame) else {
            guard MobileHostEventTopicPolicy.isDroppable(topic: topic, coalesceKey: coalesceKey) else {
                lock.unlock()
                return MobileHostEventEnqueueResult(
                    admitted: false,
                    startDrain: false,
                    shouldClose: true,
                    renderGridResyncSurfaceIDs: resyncSurfaceIDs
                )
            }
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
                renderGridResyncSurfaceIDs: resyncSurfaceIDs
            )
        }
        queuedEvents.append(QueuedEvent(topic: topic, coalesceKey: coalesceKey, frame: frame))
        queuedByteCount += frame.count
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
            renderGridResyncSurfaceIDs: resyncSurfaceIDs
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

    /// Rejects all future admissions and releases every queued payload.
    func close() {
        lock.lock()
        isClosed = true
        queuedEvents.removeAll(keepingCapacity: false)
        queuedByteCount = 0
        poisonedRenderGridSurfaceIDs.removeAll()
        resyncAfterDrainSurfaceIDs.removeAll()
        subscribedTopics.removeAll()
        lock.unlock()
    }

    private func hasRoomLocked(for frame: Data) -> Bool {
        queuedEvents.count < maximumEventCount
            && queuedByteCount + frame.count <= maximumByteCount
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
        let brokenSurfaceIDs = resyncSurfaceIDs
        queuedEvents.removeAll { event in
            guard event.topic == MobileHostEventTopicPolicy.renderGridTopic,
                  let surfaceID = event.coalesceKey,
                  brokenSurfaceIDs.contains(surfaceID) else {
                return false
            }
            freedByteCount += event.frame.count
            return true
        }
        queuedByteCount -= freedByteCount
    }
}
