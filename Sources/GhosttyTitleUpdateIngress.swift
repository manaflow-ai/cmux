import Foundation

/// Synchronous callback ingress: duplicate titles are rejected before an
/// asynchronous message is enqueued. Each ingress belongs to one Ghostty view,
/// so its newest-value stream preserves that view's final title without a
/// process-global mailbox or cross-surface contention.
final class GhosttyTitleUpdateIngress {
    private let continuation: AsyncStream<GhosttyTitleUpdateEvent>.Continuation
    private let consumerTask: Task<Void, Never>
    /// Ghostty serializes action callbacks for a view; no other context reads
    /// or writes this duplicate-rejection snapshot.
    private var lastSubmittedUpdate: GhosttyTitleUpdate?

    init(center: NotificationCenter = .default) {
        let dispatcher = GhosttyTitleUpdateDispatcher { updates in
#if DEBUG
            let timingStart = CmuxTypingTiming.start()
#endif
            for update in updates {
                let change = GhosttyTitleChange(
                    tabId: update.tabId,
                    surfaceId: update.surfaceId,
                    title: update.title,
                    sourceSurfaceIdentifier: update.sourceSurfaceIdentifier
                )
                center.post(name: .ghosttyDidSetTitle, object: nil, userInfo: change.userInfo)
            }
#if DEBUG
            CmuxTypingTiming.logDuration(
                path: "title.publish",
                startedAt: timingStart,
                extra: "published=\(updates.count)"
            )
#endif
        }
        let (events, continuation) = AsyncStream<GhosttyTitleUpdateEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        consumerTask = Task {
            for await event in events {
                switch event {
                case .update(let update):
                    await dispatcher.receive(update)
                case .retire(let surfaceKey):
                    await dispatcher.retire(surfaceKey)
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Returns false only when the update duplicates the callback-local
    /// snapshot or the ingress has already terminated.
    @discardableResult
    func submit(tabId: UUID, surfaceId: UUID, sourceSurface: AnyObject, title: String) -> Bool {
        let update = GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            sourceSurfaceIdentifier: ObjectIdentifier(sourceSurface)
        )
        guard update != lastSubmittedUpdate else { return false }
        lastSubmittedUpdate = update
        switch continuation.yield(.update(update)) {
        case .enqueued, .dropped:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func retire(_ surfaceKey: GhosttyTitleUpdateSurfaceKey) {
        _ = continuation.yield(.retire(surfaceKey))
    }
}
