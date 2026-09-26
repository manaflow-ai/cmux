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

/// Outcome of one synchronous admission attempt on a connection's event queue.
public struct MobileHostEventEnqueueResult: Sendable {
    /// The event was appended to the queue.
    public let admitted: Bool
    /// The caller must start the (single) drain task for this connection.
    public let startDrain: Bool
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

/// Synchronously admitted mailbox between event fan-out and a single drain.
/// Refresh events have a shedding budget; ordered events are retained until
/// delivery. Admission happens before task creation, so producers never create
/// a separate task retaining each event while the network is slow.
public final class MobileHostConnectionEventQueue: @unchecked Sendable {
    public struct QueuedEvent: Sendable {
        public let topic: String
        public let coalesceKey: String?
        public let frame: Data
        public let stateSeq: UInt64?
    }

    public static let defaultMaximumEventCount = 256
    public static let defaultMaximumByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount
        + MobileSyncFrameCodec.headerByteCount

    private let lock = NSLock()
    private let maximumEventCount: Int
    private let maximumByteCount: Int
    private var subscribedTopics: Set<String> = []
    private var queuedEvents: [UUID: QueuedEvent] = [:]
    private var queuedOrder: [UUID] = []
    private var queuedOrderHead = 0
    private var gridEventIDs: [String: UUID] = [:]
    private var queuedByteCount = 0
    private var drainActive = false
    private var overflowed = false
    private var isClosed = false
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
           let eventID = gridEventIDs[coalesceKey], let previous = queuedEvents[eventID] {
            // A Mac grid is an absolute snapshot. Replace the indexed entry
            // and move it to the back so older events drain first.
            let nextByteCount = queuedByteCount - previous.frame.count + frame.count
            guard nextByteCount <= maximumByteCount else {
                let result = recordOverflowLocked(shedSummary: MobileHostEventShedSummary(), resyncSurfaceIDs: [])
                lock.unlock()
                return result
            }
            queuedEvents.removeValue(forKey: eventID)
            let replacementID = UUID()
            queuedEvents[replacementID] = QueuedEvent(topic: topic, coalesceKey: coalesceKey, frame: frame, stateSeq: stateSeq)
            queuedOrder.append(replacementID)
            gridEventIDs[coalesceKey] = replacementID
            queuedByteCount = nextByteCount
            let startDrain = !drainActive
            if startDrain { drainActive = true }
            lock.unlock()
            return MobileHostEventEnqueueResult(admitted: true, startDrain: startDrain,
                renderGridResyncSurfaceIDs: [], depthAfterEnqueue: queuedEvents.count,
                shedEventCount: 0, shedByteCount: 0, simulatorFrameShedPanelIDs: [], overflowed: false)
        }
        let isRenderGrid = topic == MobileHostEventTopicPolicy().renderGridTopic
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
           MobileHostEventTopicPolicy().isDroppable(topic: topic, coalesceKey: coalesceKey) {
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
                stateSeq: stateSeq
            )
        queuedOrder.append(eventID)
        if topic == DeviceTerminalGridPublisher.eventTopic, let coalesceKey { gridEventIDs[coalesceKey] = eventID }
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
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: depthAfterEnqueue,
            shedEventCount: shedSummary.eventCount,
            shedByteCount: shedSummary.byteCount,
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
            overflowed: false
        )
    }

    public func dequeue() -> QueuedEvent? {
        lock.lock()
        defer { lock.unlock() }
        while queuedOrderHead < queuedOrder.count {
            let eventID = queuedOrder[queuedOrderHead]
            queuedOrderHead += 1
            guard let event = queuedEvents.removeValue(forKey: eventID) else { continue }
            if event.topic == DeviceTerminalGridPublisher.eventTopic, let key = event.coalesceKey,
               gridEventIDs[key] == eventID { gridEventIDs.removeValue(forKey: key) }
            queuedByteCount -= event.frame.count
            if queuedOrderHead > 64, queuedOrderHead * 2 > queuedOrder.count {
                queuedOrder.removeFirst(queuedOrderHead)
                queuedOrderHead = 0
            }
            return event
        }
        return nil
    }

    /// Called by the drain loop after `dequeue` returned nil. Returns true when
    /// events raced in and the loop must keep draining; otherwise the drain is
    /// marked finished so the next enqueue can claim a fresh one.
    public func finishDrain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A pending overflow keeps the drain alive until it consumes the flag
        // and closes the connection; otherwise no later drain would observe it.
        if (queuedEvents.isEmpty && !overflowed) || isClosed {
            drainActive = false
            return false
        }
        return true
    }

    /// Marks the drain inactive after an abnormal exit (close, lane
    /// negotiation, failed delivery) so a later enqueue can claim a fresh one.
    public func abandonDrain() {
        lock.lock()
        drainActive = false
        lock.unlock()
    }

    /// Claims the drain when events are pending and none is running (used when
    /// independent-lane negotiation finishes and delivery may resume).
    public func claimDrain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !drainActive, !queuedEvents.isEmpty || overflowed else { return false }
        drainActive = true
        return true
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
        queuedOrder.removeAll(keepingCapacity: false)
        queuedOrderHead = 0
        gridEventIDs.removeAll(keepingCapacity: false)
        overflowed = false
        queuedByteCount = 0
        poisonedRenderGridSurfaceIDs.removeAll()
        resyncAfterDrainSurfaceIDs.removeAll()
        simulatorFrameReplayAfterDrainPanelIDs.removeAll()
        subscribedTopics.removeAll()
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
    /// the drain when none is running so fan-out callers start one.
    private func recordOverflowLocked(
        shedSummary: MobileHostEventShedSummary,
        resyncSurfaceIDs: Set<String>
    ) -> MobileHostEventEnqueueResult {
        overflowed = true
        let startDrain = !drainActive
        if startDrain { drainActive = true }
        return MobileHostEventEnqueueResult(
            admitted: false, startDrain: startDrain,
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: nil, shedEventCount: shedSummary.eventCount,
            shedByteCount: shedSummary.byteCount,
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
            overflowed: true
        )
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
        var index = queuedOrderHead
        while !hasRoomLocked(for: frame), index < queuedOrder.count {
            let eventID = queuedOrder[index]
            guard let event = queuedEvents[eventID] else { index += 1; continue }
            guard MobileHostEventTopicPolicy().isDroppable(
                topic: event.topic,
                coalesceKey: event.coalesceKey
            ) else {
                index += 1
                continue
            }
            queuedEvents.removeValue(forKey: eventID)
            if event.topic == DeviceTerminalGridPublisher.eventTopic, let key = event.coalesceKey,
               gridEventIDs[key] == eventID { gridEventIDs.removeValue(forKey: key) }
            queuedByteCount -= event.frame.count
            summary.record(event)
            if event.topic == MobileHostEventTopicPolicy().renderGridTopic,
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
        var retained: [UUID] = []
        for eventID in queuedOrder {
            guard let event = queuedEvents[eventID] else { continue }
            guard event.topic == MobileHostEventTopicPolicy().renderGridTopic,
                  let surfaceID = event.coalesceKey,
                  brokenSurfaceIDs.contains(surfaceID) else {
                retained.append(eventID); continue
            }
            summary.record(event)
            cascadeByteCount += event.frame.count
            queuedEvents.removeValue(forKey: eventID)
        }
        queuedOrder = retained
        queuedOrderHead = 0
        for key in brokenSurfaceIDs { gridEventIDs.removeValue(forKey: key) }
        queuedByteCount -= cascadeByteCount
        return summary
    }
}
