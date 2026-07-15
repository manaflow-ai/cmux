import CmuxFoundation
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

    private let coalescingInterval: Duration
    private let schedule: Scheduler
    private let publish: Publisher
    private let attachmentGeneration: AtomicUInt64Generation
    private var minimumAttachmentGeneration: UInt64
    private var activeSurfaceKey: GhosttyTitleUpdateSurfaceKey?
    private var activeAttachmentGeneration: UInt64?
    private var state = GhosttyTitleUpdateSurfaceState()
    private var cancelScheduledFlush: Cancellation?

    init(
        coalescingInterval: Duration = .milliseconds(50),
        attachmentGeneration: AtomicUInt64Generation = AtomicUInt64Generation(),
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
        self.attachmentGeneration = attachmentGeneration
        minimumAttachmentGeneration = attachmentGeneration.loadRelaxed()
        self.schedule = schedule
        self.publish = publish
    }

    func receive(_ update: GhosttyTitleUpdate) {
        guard update.attachmentGeneration == attachmentGeneration.loadRelaxed(),
              update.attachmentGeneration >= minimumAttachmentGeneration else { return }
        minimumAttachmentGeneration = update.attachmentGeneration
        let key = GhosttyTitleUpdateSurfaceKey(
            surfaceId: update.surfaceId,
            sourceSurfaceIdentifier: update.sourceSurfaceIdentifier
        )
        if activeSurfaceKey != key || activeAttachmentGeneration != update.attachmentGeneration {
            reset(for: key, attachmentGeneration: update.attachmentGeneration)
        }
        guard update != state.lastReceivedUpdate else { return }
        state.lastReceivedUpdate = update
        state.pendingUpdate = update == state.lastPublishedUpdate ? nil : update
        guard state.pendingUpdate != nil else { return }
        scheduleFlushIfNeeded()
    }

    func flushNow() async {
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        await flush()
    }

    func retireUpdates(before minimumGeneration: UInt64) {
        minimumAttachmentGeneration = max(minimumAttachmentGeneration, minimumGeneration)
        guard let activeAttachmentGeneration,
              activeAttachmentGeneration < minimumAttachmentGeneration else { return }
        reset(for: nil, attachmentGeneration: nil)
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
        guard let update = state.pendingUpdate else { return }
        state.pendingUpdate = nil
        guard update.attachmentGeneration == attachmentGeneration.loadRelaxed(),
              update.attachmentGeneration >= minimumAttachmentGeneration else { return }
        state.lastPublishedUpdate = update
        await publish([update])
    }

    private func reset(
        for surfaceKey: GhosttyTitleUpdateSurfaceKey?,
        attachmentGeneration: UInt64?
    ) {
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        activeSurfaceKey = surfaceKey
        activeAttachmentGeneration = attachmentGeneration
        state = GhosttyTitleUpdateSurfaceState()
    }
}
