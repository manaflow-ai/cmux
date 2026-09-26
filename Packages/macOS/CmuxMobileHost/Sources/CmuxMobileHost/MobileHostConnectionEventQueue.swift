public import CMUXMobileCore
public import Foundation

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
/// - `simulator.frame`: video-style JPEG frames are absolute snapshots keyed by
///   panel id. When a phone cannot drain at the simulator's frame cadence, the
///   newest frame replaces older queued frames; simulator state and ownership
///   events stay lossless.
/// - `terminal.bytes`: chunks carry a byte-offset `seq`; the client detects the
///   gap and requests a replay on its own.
/// - `terminal.updated` / `workspace.updated`: level-triggered pings; the newer
///   occurrence that forced the shed supersedes the shed one.
///
/// Other topics retain their ordered payloads even beyond the shedding budget.
/// Congestion is not evidence that the connection has closed.
public struct MobileHostEventTopicPolicy: Sendable {
    public let renderGridTopic = "terminal.render_grid"
    public let simulatorFrameTopic = "simulator.frame"

    public init() {}

    public func isDroppable(topic: String, coalesceKey: String?) -> Bool {
        switch topic {
        case renderGridTopic:
            // A render-grid event without a surface key cannot be resynced
            // per-surface, so its ordered payload is retained.
            return coalesceKey != nil
        case simulatorFrameTopic:
            // Simulator frames are whole-screen snapshots; a later frame fully
            // supersedes an earlier one for the same panel.
            return coalesceKey != nil
        case "device.workspace.layout":
            // A different topic/workspace cannot replace this snapshot. The
            // viewer has no gap recovery signal, so layout changes stay lossless.
            return false
        case "terminal.bytes", "terminal.updated", "workspace.updated":
            return true
        default:
            return false
        }
    }
}

/// Delivery lane of one queued event. Every lane has its own drain, so a
/// stalled write on one lane never delays events queued on another.
///
/// `.shared` is the ordered events path (independent events stream or the
/// control stream). `.surface` carries one terminal's render-grid frames on
/// its own QUIC stream once the client negotiated surface event lanes.
public enum MobileHostEventLane: Hashable, Sendable {
    case shared
    case surface(String)
}

/// Outcome of one synchronous admission attempt on a connection's event queue.
public struct MobileHostEventEnqueueResult: Sendable {
    /// The event was appended to the queue.
    public let admitted: Bool
    /// The caller must start the drain task for ``drainLane``.
    public let startDrain: Bool
    /// The lane whose drain the caller must start when ``startDrain`` is set.
    public var drainLane: MobileHostEventLane = .shared
    /// Surfaces whose queued render-grid frames were shed; the caller must ask
    /// the producer for a full-frame resync of each.
    public let renderGridResyncSurfaceIDs: Set<String>
    /// Queue depth immediately after an admitted append.
    public let depthAfterEnqueue: Int?
    /// Count of queued droppable events removed to make room for this event.
    public let shedEventCount: Int
    /// Bytes released by shedding droppable events.
    public let shedByteCount: Int
    /// Simulator panel IDs whose queued frame snapshots were superseded.
    public let simulatorFrameShedPanelIDs: Set<String>
    /// A non-droppable event could not fit after eligible shedding. The
    /// owning connection must close rather than allowing the mailbox to grow.
    public let overflowed: Bool

    public static let rejected = MobileHostEventEnqueueResult(
        admitted: false,
        startDrain: false,
        renderGridResyncSurfaceIDs: [],
        depthAfterEnqueue: nil,
        shedEventCount: 0,
        shedByteCount: 0,
        simulatorFrameShedPanelIDs: [],
        overflowed: false
    )
}

private struct MobileHostEventShedSummary: Sendable {
    var eventCount = 0
    var byteCount = 0
    var simulatorFramePanelIDs: Set<String> = []

    mutating func record(_ event: MobileHostConnectionEventQueue.QueuedEvent) {
        eventCount += 1
        byteCount += event.frame.count
        if event.topic == MobileHostEventTopicPolicy().simulatorFrameTopic,
           let coalesceKey = event.coalesceKey {
            simulatorFramePanelIDs.insert(coalesceKey)
        }
    }
}

/// Arrival order of queued event IDs. Removing an event leaves its ID behind;
/// readers skip IDs that are no longer queued, and `compact` drops them once
/// they outnumber the live ones, so every operation stays amortized O(1).
private struct MobileHostQueuedEventOrder {
    private(set) var ids: [UUID] = []
    private(set) var head = 0

    mutating func append(_ id: UUID) {
        ids.append(id)
    }

    mutating func popFirst() -> UUID? {
        guard head < ids.count else { return nil }
        defer { head += 1 }
        return ids[head]
    }

    mutating func compact(liveCount: Int, isQueued: (UUID) -> Bool) {
        guard ids.count - head > 2 * liveCount + 64 else { return }
        ids = ids[head...].filter(isQueued)
        head = 0
    }
}

/// Synchronously admitted mailbox between event fan-out and one drain per
/// lane. Refresh events have a shedding budget; ordered events are retained
/// until delivery. Admission happens before task creation, so producers never
/// create a separate task retaining each event while the network is slow.
public final class MobileHostConnectionEventQueue: @unchecked Sendable {
    public struct QueuedEvent: Sendable {
        public let topic: String
        public let coalesceKey: String?
        public let frame: Data
        public let stateSeq: UInt64?
        public var lane: MobileHostEventLane = .shared
        /// Stream generation of a surface lane. A new generation means a new
        /// QUIC stream, so the render-grid chain must re-base on it.
        public var laneGeneration: UInt64 = 0
    }

    /// The stream a surface's render-grid chain was last admitted on. Frames
    /// on two different streams can arrive in either order, so a delta may
    /// only follow a frame that travelled the same route.
    private enum RenderGridRoute: Equatable {
        case shared
        case surface(generation: UInt64)
    }

    /// Consecutive failures after which a surface stops using its own lane
    /// and rides the shared lane until surface lanes are renegotiated.
    public static let maximumSurfaceLaneFailureCount = 3

    public static let defaultMaximumEventCount = 256
    public static let defaultMaximumByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount
        + MobileSyncFrameCodec.headerByteCount

    private let lock = NSLock()
    private let maximumEventCount: Int
    private let maximumByteCount: Int
    private var subscribedTopics: Set<String> = []
    private var queuedEvents: [UUID: QueuedEvent] = [:]
    /// Arrival order across every lane; shedding walks it oldest first.
    private var arrivalOrder = MobileHostQueuedEventOrder()
    /// Arrival order within each lane with queued events; a lane's drain
    /// dequeues from its own order.
    private var laneOrders: [MobileHostEventLane: MobileHostQueuedEventOrder] = [:]
    /// The queued Mac grid snapshot for each surface, so a newer snapshot
    /// replaces it without scanning the queue.
    private var gridEventIDs: [String: UUID] = [:]
    private var queuedByteCount = 0
    /// Lanes with a running drain. At most one drain per lane.
    private var drainingLanes: Set<MobileHostEventLane> = []
    private var overflowed = false
    private var isClosed = false
    /// Maximum concurrently assigned surface lanes; 0 disables surface lanes.
    private var surfaceLaneLimit = 0
    /// Assigned surface lanes and their last-use tick (for LRU reassignment).
    private var surfaceLaneLastUse: [String: UInt64] = [:]
    private var surfaceLaneUseTick: UInt64 = 0
    private var surfaceLaneGenerations: [String: UInt64] = [:]
    private var surfaceLaneFailureCounts: [String: Int] = [:]
    private var sharedLanePinnedSurfaceIDs: Set<String> = []
    private var queuedCountByLane: [MobileHostEventLane: Int] = [:]
    private var lastRenderGridRouteBySurfaceID: [String: RenderGridRoute] = [:]
    /// Surfaces whose delta chain was broken by a shed frame. Only a
    /// full-frame render-grid event readmits the surface; deltas are refused so
    /// the client can never apply a delta whose predecessor was dropped.
    private var poisonedRenderGridSurfaceIDs: Set<String> = []
    /// Poisoned surfaces whose replacement full frame ALSO had to be dropped
    /// (queue full of non-droppable events). Re-requested once the drain frees
    /// room, so a fully stalled connection cannot spin the producer.
    private var resyncAfterDrainSurfaceIDs: Set<String> = []
    /// Panels whose absolute snapshot was shed after the producer considered
    /// it sent. Drain progress requests one exact-session replay for each.
    private var simulatorFrameReplayAfterDrainPanelIDs: Set<String> = []

    public init(
        maximumEventCount: Int = MobileHostConnectionEventQueue.defaultMaximumEventCount,
        maximumByteCount: Int = MobileHostConnectionEventQueue.defaultMaximumByteCount
    ) {
        self.maximumEventCount = maximumEventCount
        self.maximumByteCount = maximumByteCount
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedEvents.count
    }

    public var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedByteCount
    }

    /// Event IDs held by the arrival orders, including consumed and removed
    /// ones not yet compacted away.
    var orderedIDCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return laneOrders.values.reduce(arrivalOrder.ids.count) { $0 + $1.ids.count }
    }

    /// Replaces the subscribed-topic snapshot used for synchronous admission.
    /// The owning connection calls this on subscribe/unsubscribe/close.
    public func updateSubscribedTopics(_ topics: Set<String>) {
        lock.lock()
        subscribedTopics = topics
        lock.unlock()
    }

    public func isSubscribed(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedTopics.contains(topic)
    }

    /// Synchronous admission with refresh-event shedding. Safe on any thread; never
    /// blocks on the network, the connection actor, or the runtime.
    public func enqueue(
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
        if topic == DeviceTerminalGridPublisher.eventTopic, let coalesceKey,
           let eventID = gridEventIDs[coalesceKey] {
            // A Mac grid is an absolute snapshot, so the new frame supersedes
            // the queued one. Drop the old entry and admit the new frame at
            // the back like any other grid frame, shedding droppable events
            // before an overflow closes the connection.
            _ = removeQueuedEventLocked(eventID)
        }
        let policy = MobileHostEventTopicPolicy()
        let isRenderGrid = topic == policy.renderGridTopic
        if isRenderGrid,
           let coalesceKey,
           !isFullRenderGridFrame,
           poisonedRenderGridSurfaceIDs.contains(coalesceKey) {
            // The surface's delta chain is already broken; only the pending
            // full frame may readmit it.
            lock.unlock()
            return .rejected
        }
        let (lane, laneGeneration) = laneLocked(topic: topic, coalesceKey: coalesceKey)
        var resyncSurfaceIDs = Set<String>()
        if isRenderGrid, let coalesceKey, !isFullRenderGridFrame {
            let route: RenderGridRoute = lane == .shared
                ? .shared
                : .surface(generation: laneGeneration)
            if let previousRoute = lastRenderGridRouteBySurfaceID[coalesceKey],
               previousRoute != route {
                // This delta builds on a frame that travelled another stream,
                // which may still be in flight behind it. Re-base the chain
                // with a full frame on the new route instead.
                poisonedRenderGridSurfaceIDs.insert(coalesceKey)
                lock.unlock()
                return MobileHostEventEnqueueResult(
                    admitted: false,
                    startDrain: false,
                    renderGridResyncSurfaceIDs: [coalesceKey],
                    depthAfterEnqueue: nil,
                    shedEventCount: 0,
                    shedByteCount: 0,
                    simulatorFrameShedPanelIDs: [],
                    overflowed: false
                )
            }
        }
        var shedSummary = MobileHostEventShedSummary()
        if !hasRoomLocked(for: frame) {
            shedSummary = shedDroppableEventsLocked(for: frame, resyncSurfaceIDs: &resyncSurfaceIDs)
            simulatorFrameReplayAfterDrainPanelIDs.formUnion(shedSummary.simulatorFramePanelIDs)
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
                renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                depthAfterEnqueue: nil,
                shedEventCount: shedSummary.eventCount,
                shedByteCount: shedSummary.byteCount,
                simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
                overflowed: false
            )
        }
        if !hasRoomLocked(for: frame),
           policy.isDroppable(topic: topic, coalesceKey: coalesceKey) {
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
                renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                depthAfterEnqueue: nil,
                shedEventCount: shedSummary.eventCount,
                shedByteCount: shedSummary.byteCount,
                simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
                overflowed: false
            )
        }
        if !hasRoomLocked(for: frame), topic == DeviceTerminalGridPublisher.eventTopic {
            let result = recordOverflowLocked(shedSummary: shedSummary, resyncSurfaceIDs: resyncSurfaceIDs)
            lock.unlock()
            return result
        }
        let eventID = UUID()
        queuedEvents[eventID] = QueuedEvent(
            topic: topic,
            coalesceKey: coalesceKey,
            frame: frame,
            stateSeq: stateSeq,
            lane: lane,
            laneGeneration: laneGeneration
        )
        arrivalOrder.append(eventID)
        laneOrders[lane, default: MobileHostQueuedEventOrder()].append(eventID)
        if topic == DeviceTerminalGridPublisher.eventTopic, let coalesceKey {
            gridEventIDs[coalesceKey] = eventID
        }
        queuedByteCount += frame.count
        queuedCountByLane[lane, default: 0] += 1
        let depthAfterEnqueue = queuedEvents.count
        if isRenderGrid, let coalesceKey {
            lastRenderGridRouteBySurfaceID[coalesceKey] = lane == .shared
                ? .shared
                : .surface(generation: laneGeneration)
        }
        if isRenderGrid, isFullRenderGridFrame, let coalesceKey {
            poisonedRenderGridSurfaceIDs.remove(coalesceKey)
            resyncAfterDrainSurfaceIDs.remove(coalesceKey)
        }
        let startDrain = drainingLanes.insert(lane).inserted
        lock.unlock()
        return MobileHostEventEnqueueResult(
            admitted: true,
            startDrain: startDrain,
            drainLane: lane,
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: depthAfterEnqueue,
            shedEventCount: shedSummary.eventCount,
            shedByteCount: shedSummary.byteCount,
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
            overflowed: false
        )
    }

    /// Removes the oldest event queued on `lane`. Events on other lanes keep
    /// their global order for shedding.
    public func dequeue(lane: MobileHostEventLane = .shared) -> QueuedEvent? {
        lock.lock()
        defer { lock.unlock() }
        while let eventID = laneOrders[lane]?.popFirst() {
            guard let event = removeQueuedEventLocked(eventID) else { continue }
            return event
        }
        return nil
    }

    /// Called by a lane's drain loop after `dequeue` returned nil. Returns
    /// true when events raced in and the loop must keep draining; otherwise
    /// the drain is marked finished so the next enqueue can claim a fresh one.
    public func finishDrain(lane: MobileHostEventLane = .shared) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A pending overflow keeps the shared drain alive until it consumes
        // the flag and closes the connection; otherwise no later drain would
        // observe it.
        let overflowPending = lane == .shared && overflowed
        if (queuedCountByLane[lane, default: 0] == 0 && !overflowPending) || isClosed {
            drainingLanes.remove(lane)
            return false
        }
        return true
    }

    /// Marks the lane's drain inactive after an abnormal exit (close, lane
    /// negotiation, failed delivery) so a later enqueue can claim a fresh one.
    public func abandonDrain(lane: MobileHostEventLane = .shared) {
        lock.lock()
        drainingLanes.remove(lane)
        lock.unlock()
    }

    /// Claims every lane with pending events (or the shared lane with a
    /// pending overflow) and no running drain. The caller must start one
    /// drain per returned lane.
    public func claimDrains() -> [MobileHostEventLane] {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [] }
        var claimed: [MobileHostEventLane] = []
        for (lane, count) in queuedCountByLane where count > 0 {
            if drainingLanes.insert(lane).inserted {
                claimed.append(lane)
            }
        }
        if overflowed, drainingLanes.insert(.shared).inserted {
            claimed.append(.shared)
        }
        return claimed
    }

    // MARK: Surface lanes

    /// Routes future render-grid frames onto per-surface lanes, at most
    /// `limit` at once. Surfaces beyond the limit ride the shared lane.
    public func enableSurfaceLanes(limit: Int) {
        lock.lock()
        surfaceLaneLimit = max(0, limit)
        sharedLanePinnedSurfaceIDs.removeAll()
        surfaceLaneFailureCounts.removeAll()
        lock.unlock()
    }

    public var surfaceLanesEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceLaneLimit > 0
    }

    /// Returns every future event to the shared lane. Frames still queued for
    /// a surface lane are dropped (that lane is no longer drained) and their
    /// surfaces are poisoned; the caller must request a full resync for each
    /// returned surface.
    public func disableSurfaceLanes() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard surfaceLaneLimit > 0 else { return [] }
        surfaceLaneLimit = 0
        surfaceLaneLastUse.removeAll()
        var resync = Set<String>()
        let surfaceEventIDs = queuedEvents.compactMap { entry -> UUID? in
            guard case .surface(let surfaceID) = entry.value.lane else { return nil }
            resync.insert(surfaceID)
            return entry.key
        }
        for eventID in surfaceEventIDs {
            _ = removeQueuedEventLocked(eventID)
        }
        poisonedRenderGridSurfaceIDs.formUnion(resync)
        return resync
    }

    /// Records that a surface lane stream failed or stalled. Frames written
    /// to it may be lost, so the surface's queued frames are dropped, its
    /// chain is poisoned, and the next stream gets a new generation. Returns
    /// the surfaces that need a full-frame resync. A stale `generation`
    /// (already retired) changes nothing.
    public func retireSurfaceLane(surfaceID: String, generation: UInt64) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, surfaceLaneGenerations[surfaceID, default: 0] == generation else {
            return []
        }
        surfaceLaneGenerations[surfaceID] = generation &+ 1
        surfaceLaneLastUse.removeValue(forKey: surfaceID)
        let failures = surfaceLaneFailureCounts[surfaceID, default: 0] + 1
        surfaceLaneFailureCounts[surfaceID] = failures
        if failures >= Self.maximumSurfaceLaneFailureCount {
            sharedLanePinnedSurfaceIDs.insert(surfaceID)
        }
        var droppedSummary = MobileHostEventShedSummary()
        removeRenderGridEventsLocked(surfaceIDs: [surfaceID], summary: &droppedSummary)
        poisonedRenderGridSurfaceIDs.insert(surfaceID)
        return [surfaceID]
    }

    /// Clears a surface's consecutive-failure count after a delivered frame.
    public func noteSurfaceLaneDelivered(surfaceID: String) {
        lock.lock()
        if surfaceLaneFailureCounts[surfaceID] != nil {
            surfaceLaneFailureCounts.removeValue(forKey: surfaceID)
        }
        lock.unlock()
    }

    /// Current generation of a surface's lane stream.
    public func surfaceLaneGeneration(surfaceID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return surfaceLaneGenerations[surfaceID, default: 0]
    }

    private func laneLocked(
        topic: String,
        coalesceKey: String?
    ) -> (MobileHostEventLane, UInt64) {
        guard surfaceLaneLimit > 0,
              topic == MobileHostEventTopicPolicy().renderGridTopic,
              let surfaceID = coalesceKey,
              !sharedLanePinnedSurfaceIDs.contains(surfaceID) else {
            return (.shared, 0)
        }
        surfaceLaneUseTick &+= 1
        if surfaceLaneLastUse[surfaceID] == nil {
            if surfaceLaneLastUse.count >= surfaceLaneLimit {
                // Reassign the least recently used idle lane; a lane with
                // queued or in-flight frames keeps its surface.
                let idle = surfaceLaneLastUse.filter { entry in
                    let lane = MobileHostEventLane.surface(entry.key)
                    return queuedCountByLane[lane, default: 0] == 0
                        && !drainingLanes.contains(lane)
                }
                guard let victim = idle.min(by: { $0.value < $1.value })?.key else {
                    return (.shared, 0)
                }
                surfaceLaneLastUse.removeValue(forKey: victim)
                // The victim's next frame opens a new stream.
                surfaceLaneGenerations[victim, default: 0] &+= 1
            }
        }
        surfaceLaneLastUse[surfaceID] = surfaceLaneUseTick
        return (.surface(surfaceID), surfaceLaneGenerations[surfaceID, default: 0])
    }

    /// Poisoned surfaces whose full-frame resync should be re-requested now
    /// that the drain has made progress.
    public func takeResyncAfterDrainRequests() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !resyncAfterDrainSurfaceIDs.isEmpty else { return [] }
        let requests = resyncAfterDrainSurfaceIDs
        resyncAfterDrainSurfaceIDs.removeAll()
        return requests
    }

    /// Simulator panels whose latest absolute frame must be replayed now that
    /// this exact connection's queue has made write progress.
    public func takeSimulatorFrameReplayAfterDrainRequests() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !simulatorFrameReplayAfterDrainPanelIDs.isEmpty else { return [] }
        let requests = simulatorFrameReplayAfterDrainPanelIDs
        simulatorFrameReplayAfterDrainPanelIDs.removeAll()
        return requests
    }

    /// Restores replay debt when subscription ownership changes while the
    /// connection actor is awaiting the producer callback.
    public func requeueSimulatorFrameReplayAfterDrainRequests(_ panelIDs: Set<String>) {
        guard !panelIDs.isEmpty else { return }
        lock.lock()
        if !isClosed {
            simulatorFrameReplayAfterDrainPanelIDs.formUnion(panelIDs)
        }
        lock.unlock()
    }

    /// Rejects all future admissions and releases every queued payload.
    public func close() {
        lock.lock()
        isClosed = true
        queuedEvents.removeAll(keepingCapacity: false)
        arrivalOrder = MobileHostQueuedEventOrder()
        laneOrders.removeAll(keepingCapacity: false)
        gridEventIDs.removeAll(keepingCapacity: false)
        overflowed = false
        queuedByteCount = 0
        poisonedRenderGridSurfaceIDs.removeAll()
        resyncAfterDrainSurfaceIDs.removeAll()
        simulatorFrameReplayAfterDrainPanelIDs.removeAll()
        subscribedTopics.removeAll()
        queuedCountByLane.removeAll()
        surfaceLaneLimit = 0
        surfaceLaneLastUse.removeAll()
        lastRenderGridRouteBySurfaceID.removeAll()
        lock.unlock()
    }

    /// Consumed by the connection's existing drain lifecycle so overflow closes
    /// without spawning an untracked task from synchronous fan-out.
    public func consumeOverflow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard overflowed else { return false }
        overflowed = false
        return true
    }

    /// Every overflow result goes through here: the pending flag is the only
    /// signal the drain uses to close the connection, and the result claims
    /// the shared drain (where Mac grid snapshots travel) when none is
    /// running so fan-out callers start one.
    private func recordOverflowLocked(
        shedSummary: MobileHostEventShedSummary,
        resyncSurfaceIDs: Set<String>
    ) -> MobileHostEventEnqueueResult {
        overflowed = true
        let startDrain = drainingLanes.insert(.shared).inserted
        return MobileHostEventEnqueueResult(
            admitted: false, startDrain: startDrain, drainLane: .shared,
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: nil, shedEventCount: shedSummary.eventCount,
            shedByteCount: shedSummary.byteCount,
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
            overflowed: true
        )
    }

    /// Removes one queued event and every index that points at it. The
    /// arrival orders keep its ID until they skip or compact it.
    private func removeQueuedEventLocked(_ eventID: UUID) -> QueuedEvent? {
        guard let event = queuedEvents.removeValue(forKey: eventID) else { return nil }
        queuedByteCount -= event.frame.count
        if event.topic == DeviceTerminalGridPublisher.eventTopic, let key = event.coalesceKey,
           gridEventIDs[key] == eventID {
            gridEventIDs.removeValue(forKey: key)
        }
        let remaining = queuedCountByLane[event.lane, default: 0] - 1
        if remaining > 0 {
            queuedCountByLane[event.lane] = remaining
            laneOrders[event.lane]?.compact(liveCount: remaining) { queuedEvents[$0] != nil }
        } else {
            queuedCountByLane.removeValue(forKey: event.lane)
            laneOrders.removeValue(forKey: event.lane)
        }
        arrivalOrder.compact(liveCount: queuedEvents.count) { queuedEvents[$0] != nil }
        return event
    }

    /// Drops every queued render-grid frame for `surfaceIDs`, on any lane.
    private func removeRenderGridEventsLocked(
        surfaceIDs: Set<String>,
        summary: inout MobileHostEventShedSummary
    ) {
        let renderGridTopic = MobileHostEventTopicPolicy().renderGridTopic
        let eventIDs = queuedEvents.compactMap { entry -> UUID? in
            guard entry.value.topic == renderGridTopic,
                  let surfaceID = entry.value.coalesceKey,
                  surfaceIDs.contains(surfaceID) else { return nil }
            return entry.key
        }
        for eventID in eventIDs {
            if let event = removeQueuedEventLocked(eventID) {
                summary.record(event)
            }
        }
    }

    private func hasRoomLocked(for frame: Data) -> Bool {
        queuedEvents.count < maximumEventCount
            && queuedByteCount + frame.count <= maximumByteCount
    }

    private func shedDroppableEventsLocked(
        for frame: Data,
        resyncSurfaceIDs: inout Set<String>
    ) -> MobileHostEventShedSummary {
        let policy = MobileHostEventTopicPolicy()
        var summary = MobileHostEventShedSummary()
        var sheddable: [UUID] = []
        var releasedCount = 0
        var releasedBytes = 0
        // Pick the oldest droppable events first, then remove them, so the
        // walk never sees the order compact under it.
        for eventID in arrivalOrder.ids[arrivalOrder.head...] {
            if queuedEvents.count - releasedCount < maximumEventCount,
               queuedByteCount - releasedBytes + frame.count <= maximumByteCount {
                break
            }
            guard let event = queuedEvents[eventID],
                  policy.isDroppable(topic: event.topic, coalesceKey: event.coalesceKey) else {
                continue
            }
            sheddable.append(eventID)
            releasedCount += 1
            releasedBytes += event.frame.count
        }
        for eventID in sheddable {
            guard let event = removeQueuedEventLocked(eventID) else { continue }
            summary.record(event)
            if event.topic == policy.renderGridTopic,
               let surfaceID = event.coalesceKey,
               poisonedRenderGridSurfaceIDs.insert(surfaceID).inserted {
                resyncSurfaceIDs.insert(surfaceID)
            }
        }
        // A shed frame breaks its surface's delta chain, so every remaining
        // queued render-grid frame for that surface — each builds on the shed
        // one — must go with it. The pending full-frame resync re-bases the
        // chain for the whole connection.
        guard !resyncSurfaceIDs.isEmpty else { return summary }
        removeRenderGridEventsLocked(surfaceIDs: resyncSurfaceIDs, summary: &summary)
        return summary
    }
}
