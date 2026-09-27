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
enum MobileHostEventTopicPolicy {
    static let renderGridTopic = "terminal.render_grid"
    static let simulatorFrameTopic = "simulator.frame"

    static func isDroppable(topic: String, coalesceKey: String?) -> Bool {
        switch topic {
        case renderGridTopic:
            // A render-grid event without a surface key cannot be resynced
            // per-surface, so its ordered payload is retained.
            return coalesceKey != nil
        case simulatorFrameTopic:
            // Simulator frames are whole-screen snapshots; a later frame fully
            // supersedes an earlier one for the same panel.
            return coalesceKey != nil
        case DeviceWorkspaceLayoutHost.eventTopic:
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
enum MobileHostEventLane: Hashable, Sendable {
    case shared
    case surface(String)
}

/// Outcome of one synchronous admission attempt on a connection's event queue.
struct MobileHostEventEnqueueResult: Sendable {
    /// The event was appended to the queue.
    let admitted: Bool
    /// The caller must start the drain task for ``drainLane``.
    let startDrain: Bool
    /// The lane whose drain the caller must start when ``startDrain`` is set.
    var drainLane: MobileHostEventLane = .shared
    /// Surfaces whose queued render-grid frames were shed; the caller must ask
    /// the producer for a full-frame resync of each.
    let renderGridResyncSurfaceIDs: Set<String>
    /// Queue depth immediately after an admitted append.
    let depthAfterEnqueue: Int?
    /// Count of queued droppable events removed to make room for this event.
    let shedEventCount: Int
    /// Bytes released by shedding droppable events.
    let shedByteCount: Int
    /// Simulator panel IDs whose queued frame snapshots were superseded.
    let simulatorFrameShedPanelIDs: Set<String>

    static let rejected = MobileHostEventEnqueueResult(
        admitted: false,
        startDrain: false,
        renderGridResyncSurfaceIDs: [],
        depthAfterEnqueue: nil,
        shedEventCount: 0,
        shedByteCount: 0,
        simulatorFrameShedPanelIDs: []
    )
}

private struct MobileHostEventShedSummary: Sendable {
    var eventCount = 0
    var byteCount = 0
    var simulatorFramePanelIDs: Set<String> = []

    mutating func record(_ event: MobileHostConnectionEventQueue.QueuedEvent) {
        eventCount += 1
        byteCount += event.frame.count
        if event.topic == MobileHostEventTopicPolicy.simulatorFrameTopic,
           let coalesceKey = event.coalesceKey {
            simulatorFramePanelIDs.insert(coalesceKey)
        }
    }
}

/// Synchronously admitted mailbox between event fan-out and a single drain.
/// Refresh events have a shedding budget; ordered events are retained until
/// delivery. Admission happens before task creation, so producers never create
/// a separate task retaining each event while the network is slow.
final class MobileHostConnectionEventQueue: @unchecked Sendable {
    struct QueuedEvent: Sendable {
        let topic: String
        let coalesceKey: String?
        let frame: Data
        let stateSeq: UInt64?
        var lane: MobileHostEventLane = .shared
        /// Stream generation of a surface lane. A new generation means a new
        /// QUIC stream, so the render-grid chain must re-base on it.
        var laneGeneration: UInt64 = 0
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
    static let maximumSurfaceLaneFailureCount = 3

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
    /// Lanes with a running drain. At most one drain per lane.
    private var drainingLanes: Set<MobileHostEventLane> = []
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

    /// Synchronous admission with refresh-event shedding. Safe on any thread; never
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
                    simulatorFrameShedPanelIDs: []
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
                simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs
            )
        }
        if !hasRoomLocked(for: frame),
           MobileHostEventTopicPolicy.isDroppable(topic: topic, coalesceKey: coalesceKey) {
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
                simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs
            )
        }
        queuedEvents.append(
            QueuedEvent(
                topic: topic,
                coalesceKey: coalesceKey,
                frame: frame,
                stateSeq: stateSeq,
                lane: lane,
                laneGeneration: laneGeneration
            )
        )
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
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs
        )
    }

    /// Removes the oldest event queued on `lane`. Events on other lanes keep
    /// their global order for shedding.
    func dequeue(lane: MobileHostEventLane = .shared) -> QueuedEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard queuedCountByLane[lane, default: 0] > 0,
              let index = queuedEvents.firstIndex(where: { $0.lane == lane }) else {
            return nil
        }
        let event = queuedEvents.remove(at: index)
        queuedByteCount -= event.frame.count
        decrementLaneCountLocked(lane)
        return event
    }

    /// Called by a lane's drain loop after `dequeue` returned nil. Returns
    /// true when events raced in and the loop must keep draining; otherwise
    /// the drain is marked finished so the next enqueue can claim a fresh one.
    func finishDrain(lane: MobileHostEventLane = .shared) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if queuedCountByLane[lane, default: 0] == 0 || isClosed {
            drainingLanes.remove(lane)
            return false
        }
        return true
    }

    /// Marks the lane's drain inactive after an abnormal exit (close, lane
    /// negotiation, failed delivery) so a later enqueue can claim a fresh one.
    func abandonDrain(lane: MobileHostEventLane = .shared) {
        lock.lock()
        drainingLanes.remove(lane)
        lock.unlock()
    }

    /// Claims the shared lane's drain when events are pending and none is
    /// running (used when independent-lane negotiation finishes).
    func claimDrain() -> Bool {
        claimDrains().contains(.shared)
    }

    /// Claims every lane with pending events and no running drain. The caller
    /// must start one drain per returned lane.
    func claimDrains() -> [MobileHostEventLane] {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [] }
        var claimed: [MobileHostEventLane] = []
        for (lane, count) in queuedCountByLane where count > 0 {
            if drainingLanes.insert(lane).inserted {
                claimed.append(lane)
            }
        }
        return claimed
    }

    // MARK: Surface lanes

    /// Routes future render-grid frames onto per-surface lanes, at most
    /// `limit` at once. Surfaces beyond the limit ride the shared lane.
    func enableSurfaceLanes(limit: Int) {
        lock.lock()
        surfaceLaneLimit = max(0, limit)
        sharedLanePinnedSurfaceIDs.removeAll()
        surfaceLaneFailureCounts.removeAll()
        lock.unlock()
    }

    var surfaceLanesEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceLaneLimit > 0
    }

    /// Returns every future event to the shared lane. Frames still queued for
    /// a surface lane are dropped (that lane is no longer drained) and their
    /// surfaces are poisoned; the caller must request a full resync for each
    /// returned surface.
    func disableSurfaceLanes() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard surfaceLaneLimit > 0 else { return [] }
        surfaceLaneLimit = 0
        surfaceLaneLastUse.removeAll()
        var resync = Set<String>()
        var droppedByteCount = 0
        queuedEvents.removeAll { event in
            guard case .surface(let surfaceID) = event.lane else { return false }
            resync.insert(surfaceID)
            droppedByteCount += event.frame.count
            return true
        }
        queuedByteCount -= droppedByteCount
        for lane in queuedCountByLane.keys where lane != .shared {
            queuedCountByLane.removeValue(forKey: lane)
        }
        poisonedRenderGridSurfaceIDs.formUnion(resync)
        return resync
    }

    /// Records that a surface lane stream failed or stalled. Frames written
    /// to it may be lost, so the surface's queued frames are dropped, its
    /// chain is poisoned, and the next stream gets a new generation. Returns
    /// the surfaces that need a full-frame resync. A stale `generation`
    /// (already retired) changes nothing.
    func retireSurfaceLane(surfaceID: String, generation: UInt64) -> Set<String> {
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
        var droppedByteCount = 0
        queuedEvents.removeAll { event in
            guard event.topic == MobileHostEventTopicPolicy.renderGridTopic,
                  event.coalesceKey == surfaceID else { return false }
            droppedByteCount += event.frame.count
            decrementLaneCountLocked(event.lane)
            return true
        }
        queuedByteCount -= droppedByteCount
        poisonedRenderGridSurfaceIDs.insert(surfaceID)
        return [surfaceID]
    }

    /// Clears a surface's consecutive-failure count after a delivered frame.
    func noteSurfaceLaneDelivered(surfaceID: String) {
        lock.lock()
        if surfaceLaneFailureCounts[surfaceID] != nil {
            surfaceLaneFailureCounts.removeValue(forKey: surfaceID)
        }
        lock.unlock()
    }

    /// Current generation of a surface's lane stream.
    func surfaceLaneGeneration(surfaceID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return surfaceLaneGenerations[surfaceID, default: 0]
    }

    private func laneLocked(
        topic: String,
        coalesceKey: String?
    ) -> (MobileHostEventLane, UInt64) {
        guard surfaceLaneLimit > 0,
              topic == MobileHostEventTopicPolicy.renderGridTopic,
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

    private func decrementLaneCountLocked(_ lane: MobileHostEventLane) {
        let remaining = queuedCountByLane[lane, default: 0] - 1
        if remaining > 0 {
            queuedCountByLane[lane] = remaining
        } else {
            queuedCountByLane.removeValue(forKey: lane)
        }
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

    /// Simulator panels whose latest absolute frame must be replayed now that
    /// this exact connection's queue has made write progress.
    func takeSimulatorFrameReplayAfterDrainRequests() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !simulatorFrameReplayAfterDrainPanelIDs.isEmpty else { return [] }
        let requests = simulatorFrameReplayAfterDrainPanelIDs
        simulatorFrameReplayAfterDrainPanelIDs.removeAll()
        return requests
    }

    /// Restores replay debt when subscription ownership changes while the
    /// connection actor is awaiting the producer callback.
    func requeueSimulatorFrameReplayAfterDrainRequests(_ panelIDs: Set<String>) {
        guard !panelIDs.isEmpty else { return }
        lock.lock()
        if !isClosed {
            simulatorFrameReplayAfterDrainPanelIDs.formUnion(panelIDs)
        }
        lock.unlock()
    }

    /// Rejects all future admissions and releases every queued payload.
    func close() {
        lock.lock()
        isClosed = true
        queuedEvents.removeAll(keepingCapacity: false)
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

    private func hasRoomLocked(for frame: Data) -> Bool {
        queuedEvents.count < maximumEventCount
            && queuedByteCount + frame.count <= maximumByteCount
    }

    private func shedDroppableEventsLocked(
        for frame: Data,
        resyncSurfaceIDs: inout Set<String>
    ) -> MobileHostEventShedSummary {
        var summary = MobileHostEventShedSummary()
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
            decrementLaneCountLocked(event.lane)
            summary.record(event)
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
        guard !resyncSurfaceIDs.isEmpty else { return summary }
        let brokenSurfaceIDs = resyncSurfaceIDs
        var cascadeByteCount = 0
        queuedEvents.removeAll { event in
            guard event.topic == MobileHostEventTopicPolicy.renderGridTopic,
                  let surfaceID = event.coalesceKey,
                  brokenSurfaceIDs.contains(surfaceID) else {
                return false
            }
            summary.record(event)
            cascadeByteCount += event.frame.count
            decrementLaneCountLocked(event.lane)
            return true
        }
        queuedByteCount -= cascadeByteCount
        return summary
    }
}
