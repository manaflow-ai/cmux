import Foundation

/// Owns title-churn policy before any work reaches the main actor.
///
/// Updates are independently coalesced per surface. A continuously animated
/// title publishes at most once per interval, while the final title is always
/// retained for the next flush.
actor GhosttyTitleUpdateDispatcher {
    typealias Publisher = @MainActor @Sendable ([GhosttyTitleUpdate]) -> Void
    typealias Cancellation = @Sendable () -> Void
    typealias Scheduler = @Sendable (
        Duration,
        @escaping @Sendable () async -> Void
    ) -> Cancellation

    private struct SurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID
        let sourceSurfaceIdentifier: ObjectIdentifier
    }

    private struct SurfaceState {
        var lastSequence: UInt64 = 0
        var lastReceivedTitle: String?
        var lastPublishedTitle: String?
        var pendingUpdate: GhosttyTitleUpdate?
    }

    private let coalescingInterval: Duration
    private let schedule: Scheduler
    private let publish: Publisher
    private var states: [SurfaceKey: SurfaceState] = [:]
    private var cancelScheduledFlush: Cancellation?

    init(
        coalescingInterval: Duration = .milliseconds(50),
        schedule: @escaping Scheduler = { interval, action in
            let task = Task {
                // This cancellable delay is the intended title-publication window, not a readiness poll.
                try? await ContinuousClock().sleep(for: interval)
                guard !Task.isCancelled else { return }
                await action()
            }
            return { task.cancel() }
        },
        publish: @escaping Publisher
    ) {
        self.coalescingInterval = coalescingInterval
        self.schedule = schedule
        self.publish = publish
    }

    func receive(_ update: GhosttyTitleUpdate) {
        let key = SurfaceKey(
            tabId: update.tabId,
            surfaceId: update.surfaceId,
            sourceSurfaceIdentifier: update.sourceSurfaceIdentifier
        )
        var state = states[key] ?? SurfaceState()
        guard update.sequence > state.lastSequence else { return }
        state.lastSequence = update.sequence
        guard update.title != state.lastReceivedTitle else {
            states[key] = state
            return
        }
        state.lastReceivedTitle = update.title
        state.pendingUpdate = update.title == state.lastPublishedTitle ? nil : update
        states[key] = state
        scheduleFlushIfNeeded()
    }

    func flushNow() async {
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        await flush()
    }

    func retire(tabId: UUID, surfaceId: UUID, sourceSurfaceIdentifier: ObjectIdentifier) {
        states.removeValue(forKey: SurfaceKey(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier
        ))
    }

    private func scheduleFlushIfNeeded() {
        guard cancelScheduledFlush == nil else { return }
        cancelScheduledFlush = schedule(coalescingInterval) { [weak self] in
            await self?.scheduledFlushDidFire()
        }
    }

    private func scheduledFlushDidFire() async {
        cancelScheduledFlush = nil
        await flush()
    }

    private func flush() async {
        var updates: [GhosttyTitleUpdate] = []
        updates.reserveCapacity(states.count)
        for key in Array(states.keys) {
            guard var state = states[key], let update = state.pendingUpdate else { continue }
            state.pendingUpdate = nil
            state.lastPublishedTitle = update.title
            states[key] = state
            updates.append(update)
        }
        guard !updates.isEmpty else { return }
        await publish(updates)
    }
}
