import Foundation

@MainActor
final class ApplicationSurfaceInputPump {
    enum EnqueueResult: Equatable {
        case accepted
        case full
    }

    typealias Sender = @MainActor (ApplicationSurfaceInputEvent) async -> Bool

    private let maximumQueuedEventCount: Int
    private let sender: Sender
    private var queue: [ApplicationSurfaceInputEvent] = []
    private var drainTask: Task<Void, Never>?
    private var possiblyPressedKeyCodes: Set<UInt16> = []
    private var possiblyPressedLeftMouseLocation: CGPoint?
    private var possiblyPressedRightMouseLocation: CGPoint?

    init(
        maximumQueuedEventCount: Int = 64,
        sender: @escaping Sender
    ) {
        precondition(maximumQueuedEventCount > 0)
        self.maximumQueuedEventCount = maximumQueuedEventCount
        self.sender = sender
    }

    @discardableResult
    func enqueue(_ event: ApplicationSurfaceInputEvent) -> EnqueueResult {
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
    func enqueue(_ events: [ApplicationSurfaceInputEvent]) -> EnqueueResult {
        guard !events.isEmpty else { return .accepted }
        guard makeRoom(for: events.count) else { return .full }
        queue.append(contentsOf: events)
        startDrainIfNeeded()
        return .accepted
    }

    func discardPendingAndTakeReleaseEvents() async -> [ApplicationSurfaceInputEvent] {
        queue.removeAll(keepingCapacity: true)
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
                x: point.x,
                y: point.y
            ))
        }
        if let point = possiblyPressedRightMouseLocation {
            releases.append(ApplicationSurfaceInputEvent(
                kind: .rightMouseUp,
                x: point.x,
                y: point.y
            ))
        }
        possiblyPressedKeyCodes.removeAll(keepingCapacity: true)
        possiblyPressedLeftMouseLocation = nil
        possiblyPressedRightMouseLocation = nil
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
                let event = self.queue.removeFirst()
                self.recordPossibleDelivery(of: event)
                let delivered = await self.sender(event)
                self.recordAcknowledgedDelivery(of: event, delivered: delivered)
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
        case .rightMouseDown:
            possiblyPressedRightMouseLocation = CGPoint(x: event.x, y: event.y)
        case .leftMouseDragged where possiblyPressedLeftMouseLocation != nil:
            possiblyPressedLeftMouseLocation = CGPoint(x: event.x, y: event.y)
        case .rightMouseDragged where possiblyPressedRightMouseLocation != nil:
            possiblyPressedRightMouseLocation = CGPoint(x: event.x, y: event.y)
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
        case .rightMouseUp:
            possiblyPressedRightMouseLocation = nil
        default:
            break
        }
    }
}
