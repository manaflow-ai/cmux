import Foundation

@MainActor
final class ApplicationSurfaceInputPump {
    typealias BatchSender = @MainActor ([ApplicationSurfaceInputEvent]) async -> Bool
    private static let maximumProtocolBatchEventCount = 64

    private let maximumQueuedEventCount: Int
    private let batchSender: BatchSender
    private var queue: [ApplicationSurfaceInputEvent] = []
    private var drainTask: Task<Void, Never>?
    private var possiblyPressedKeyCodes: Set<UInt16> = []
    private var possiblyPressedLeftMouseLocation: CGPoint?
    private var possiblyPressedLeftMouseFrameSequence: UInt64?
    private var possiblyPressedRightMouseLocation: CGPoint?
    private var possiblyPressedRightMouseFrameSequence: UInt64?

    init(
        maximumQueuedEventCount: Int = 64,
        batchSender: @escaping BatchSender
    ) {
        precondition(maximumQueuedEventCount > 0)
        self.maximumQueuedEventCount = maximumQueuedEventCount
        self.batchSender = batchSender
    }

    @discardableResult
    func enqueue(_ event: ApplicationSurfaceInputEvent) -> ApplicationSurfaceInputEnqueueResult {
        if event.kind == .scroll,
           let lastIndex = queue.indices.last,
           queue[lastIndex].kind == .scroll,
           queue[lastIndex].modifiers == event.modifiers {
            var coalesced = event
            coalesced.deltaX += queue[lastIndex].deltaX
            coalesced.deltaY += queue[lastIndex].deltaY
            queue[lastIndex] = coalesced
            return .accepted
        }
        if event.kind.isCoalescibleMotion,
           let lastIndex = queue.indices.last,
           queue[lastIndex].kind.isCoalescibleMotion {
            queue[lastIndex] = event
            return .accepted
        }
        guard makeRoom(for: 1) else { return .full }
        queue.append(event)
        startDrainIfNeeded()
        return .accepted
    }

    @discardableResult
    func enqueue(_ events: [ApplicationSurfaceInputEvent]) -> ApplicationSurfaceInputEnqueueResult {
        guard !events.isEmpty else { return .accepted }
        guard makeRoom(for: events.count) else { return .full }
        queue.append(contentsOf: events)
        startDrainIfNeeded()
        return .accepted
    }

    func discardPendingAndTakeReleaseEvents() async -> [ApplicationSurfaceInputEvent] {
        discardPending()
        return await takeReleaseEventsAfterDraining()
    }

    func discardPending() {
        queue.removeAll(keepingCapacity: true)
    }

    func takeReleaseEventsAfterDraining() async -> [ApplicationSurfaceInputEvent] {
        await waitUntilIdle()

        var releases = possiblyPressedKeyCodes
            .sorted()
            .map {
                ApplicationSurfaceInputEvent(
                    kind: .key,
                    keyCode: $0,
                    keyDown: false
                )
            }
        if let point = possiblyPressedLeftMouseLocation {
            releases.append(ApplicationSurfaceInputEvent(
                kind: .leftMouseUp,
                frameSequence: possiblyPressedLeftMouseFrameSequence ?? 0,
                x: point.x,
                y: point.y
            ))
        }
        if let point = possiblyPressedRightMouseLocation {
            releases.append(ApplicationSurfaceInputEvent(
                kind: .rightMouseUp,
                frameSequence: possiblyPressedRightMouseFrameSequence ?? 0,
                x: point.x,
                y: point.y
            ))
        }
        possiblyPressedKeyCodes.removeAll(keepingCapacity: true)
        possiblyPressedLeftMouseLocation = nil
        possiblyPressedLeftMouseFrameSequence = nil
        possiblyPressedRightMouseLocation = nil
        possiblyPressedRightMouseFrameSequence = nil
        return releases
    }

    func waitUntilIdle() async {
        while let drainTask {
            await drainTask.value
        }
    }

    private func makeRoom(for eventCount: Int) -> Bool {
        guard eventCount <= maximumQueuedEventCount else { return false }
        if queue.count + eventCount <= maximumQueuedEventCount {
            return true
        }
        queue.removeAll(where: \.kind.isCoalescibleMotion)
        return queue.count + eventCount <= maximumQueuedEventCount
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty {
                let pending = self.queue
                self.queue.removeAll(keepingCapacity: true)
                for startIndex in stride(
                    from: 0,
                    to: pending.count,
                    by: Self.maximumProtocolBatchEventCount
                ) {
                    let endIndex = min(
                        startIndex + Self.maximumProtocolBatchEventCount,
                        pending.count
                    )
                    let batch = Array(pending[startIndex ..< endIndex])
                    for event in batch {
                        self.recordPossibleDelivery(of: event)
                    }
                    let delivered = await self.batchSender(batch)
                    for event in batch {
                        self.recordAcknowledgedDelivery(
                            of: event,
                            delivered: delivered
                        )
                    }
                }
            }
            self.drainTask = nil
            if !self.queue.isEmpty {
                self.startDrainIfNeeded()
            }
        }
    }

    private func recordPossibleDelivery(of event: ApplicationSurfaceInputEvent) {
        switch event.kind {
        case .key where event.keyDown:
            possiblyPressedKeyCodes.insert(event.keyCode)
        case .leftMouseDown:
            possiblyPressedLeftMouseLocation = CGPoint(x: event.x, y: event.y)
            possiblyPressedLeftMouseFrameSequence = event.frameSequence
        case .rightMouseDown:
            possiblyPressedRightMouseLocation = CGPoint(x: event.x, y: event.y)
            possiblyPressedRightMouseFrameSequence = event.frameSequence
        case .leftMouseDragged where possiblyPressedLeftMouseLocation != nil:
            possiblyPressedLeftMouseLocation = CGPoint(x: event.x, y: event.y)
            possiblyPressedLeftMouseFrameSequence = event.frameSequence
        case .rightMouseDragged where possiblyPressedRightMouseLocation != nil:
            possiblyPressedRightMouseLocation = CGPoint(x: event.x, y: event.y)
            possiblyPressedRightMouseFrameSequence = event.frameSequence
        default:
            break
        }
    }

    private func recordAcknowledgedDelivery(
        of event: ApplicationSurfaceInputEvent,
        delivered: Bool
    ) {
        guard delivered else { return }
        switch event.kind {
        case .key where !event.keyDown:
            possiblyPressedKeyCodes.remove(event.keyCode)
        case .leftMouseUp:
            possiblyPressedLeftMouseLocation = nil
            possiblyPressedLeftMouseFrameSequence = nil
        case .rightMouseUp:
            possiblyPressedRightMouseLocation = nil
            possiblyPressedRightMouseFrameSequence = nil
        default:
            break
        }
    }
}
